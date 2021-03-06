require 'pry'
# require 'ruby-poker'

class Round < ApplicationRecord
    belongs_to :game
    has_many :users

    #phase
    #small_blind_index
    #turn_index
    #pot
    #highest_bet_for_phase
    #is_playing
    #no_players_for_phase
    #turn_count
    #community_cards
    #all_in
    #seats
    #status (removed)
    #result (removed)
    #big_blind

    PRE_FLOP = 0
    FLOP = 1
    TURN = 2
    RIVER = 3

    def as_json(options = {})
        # super(only: [:id, :pot, :highest_bet_for_phase, :is_playing, :phase, :result, :big_blind], methods: [:access_community_cards, :turn])
        super(only: [:id, :pot, :highest_bet_for_phase, :is_playing, :phase, :big_blind], methods: [:access_community_cards, :turn_as_json])
    end 

    def turn_as_json
        turn.as_json(only: [:id], methods: [:possible_moves]) if turn
    end

    def turn 
        self.is_playing ? User.find(self.seats[self.turn_index]) : nil
    end

    def turn= (user)
        self.turn_index = self.seats.find_index(user.id)
        self.save
    end

    def access_community_cards
        case self.phase
        when PRE_FLOP
            return ""
        when FLOP
            return self.community_cards[0..7]
        when TURN
            return self.community_cards[0..10]
        else
            return self.community_cards
        end
    end

    def player_ids # It might be better to just use this one, less queries to the db.
        self.seats.select{|i| !!i }
    end

    def active_player_ids # When we use this one we have to query the database extra.
        self.seats.select{|i| !!i && User.find(i).playing }
    end

    def phase_finished?
        players_have_bet? && self.turn_count > self.no_players_for_phase
    end

    def players_have_bet? #fix
        player_ids.each do |id|
            player = User.find(id)
            return false if player.round_bet < self.highest_bet_for_phase && player.playing
        end
    end

    def start
        # self.status << "ROUND STARTING"
        # puts "ALLOOOO??"
        self.game.users.each {|p| p.set_playing(self.id) }

        # puts 'hiiiiii'
        self.seats = self.game.seats
        self.is_playing = true

        # puts 'did i get here??'
        set_dealer
        set_cards
        start_preflop

        self.save
    end

    def start_preflop
        self.turn_index = self.small_blind_index
        self.no_players_for_phase = player_ids.count
        self.highest_bet_for_phase = 0
        self.turn_count = 1

        self.make_player_move('raise', self.big_blind / 2, true)
        self.make_player_move('raise', self.big_blind, true)
        self.save
    end

    def set_dealer
        dealer_index = self.small_blind_index
        while !self.seats[dealer_index] || dealer_index != self.small_blind_index
            dealer_index = (dealer_index - 1) % 8
        end

        u = User.find(self.seats[dealer_index])
        u.dealer = true
        u.save
    end

    def player_has_left(user) # this will get reworked once i change the arrays around ...
        index = self.seats.find_index(user.id)

        self.seats[index] = nil
        self.users.delete(user)
        self.save

        if !check_if_over && turn_index == index
            next_turn
            initiate_next_phase if phase_finished?
            make_marley_move
            # phase_finished?  initiate_next_phase : make_marley_move
        elsif check_if_over
            end_game_by_fold
        end
    end

    # def end_game_by_leave
    #     index = self.seats.index{|p| User.find(p).playing }
    #     last_player = User.find(self.seats[index])

    #     # last_player = User.find(self.active_player_ids[0])
    #     last_player.chips += self.pot
    #     last_player.winnings = self.pot
    #     last_player.save

    #     self.is_playing = false
    #     self.save

    #     sleep 0.80
    #     ActionCable.server.broadcast("game_#{self.game.id}", { 
    #             type: "game_end_by_leave",
    #             startable: self.game.startable,
    #             winner_index: index,
    #             winnings: self.pot,
    #             winner_ids: { last_player.id => true } 
    #         }) 
    # end

    def set_cards
        # self.status << "...Dealing cards..."
        deck = []
        ['c', 'd', 'h', 's'].each do |color|
            [2, 3, 4, 5, 6, 7, 8, 9, 'T', 'J', 'Q', 'K', 'A'].each do |number|
                deck << number.to_s + color
            end
        end

        community_cards = []
        5.times { community_cards << deck.delete_at(Random.rand(deck.length)) }
        self.community_cards = community_cards.join(' ')
        self.save

        player_ids.each do |id|
            player = User.find(id)
            player.cards = "#{deck.delete_at(Random.rand(deck.length))} #{deck.delete_at(Random.rand(deck.length))}"
            player.save
        end
    end

    def reset_turn_index # Responsible for finding first person to go in each round.
        i = (self.small_blind_index + 1) % 8
        while true 
            if self.seats[i] && User.find(self.seats[i]).playing
                self.turn = User.find(self.seats[i])
                break
            end
            i = (i + 1) % 8
        end
        self.save
    end

    def start_betting_round
        player_ids.each do |id|
            player = User.find(id)
            player.round_bet = 0
            player.checked = false
            player.save
        end

        reset_turn_index
        self.no_players_for_phase = player_ids.count
        self.highest_bet_for_phase = 0
        self.turn_count = 1

        self.save
    end

    def next_turn(blinds = false)
        self.turn_index = (self.turn_index + 1) % 8
        while !self.seats[self.turn_index] || !User.find(self.seats[self.turn_index]).playing
            self.turn_index = (self.turn_index + 1) % 8
        end

        self.turn_count += 1 unless blinds
        self.save

        if !blinds && self.is_playing && !phase_finished? && !check_if_over
            sleep 0.80
            ActionCable.server.broadcast("game_#{game.id}", { type: "update_turn", turn_as_json: turn_as_json })
        end

    end

    def check_if_over
        counter = 0
        player_ids.each do |id|
            counter += 1 if User.find(id).playing
            return false if counter == 2
        end
    end

    def make_player_move(command, amount = 0, blinds = false)
        # These variables I need when I broadcast to ActionCable
        u = turn 
        turn_index = self.turn_index
        
        case command
        when 'fold'
            u.playing = false
            u.save

            # next_turn
        when 'check'
            if self.highest_bet_for_phase == 0 || u.round_bet == self.highest_bet_for_phase
                u.checked = true
                u.save

                # next_turn
            end
        when 'call'
            if self.highest_bet_for_phase > u.round_bet || self.highest_bet_for_phase == 0
                chip_change = self.highest_bet_for_phase - u.round_bet #Don't delete this.
                u.round_bet = self.highest_bet_for_phase
                u.chips -= chip_change
                u.save

                self.all_in = true if u.chips == 0
                self.pot += chip_change
                # next_turn
            end
        when 'raise'
            if can_players_afford?(amount) && amount > self.highest_bet_for_phase
                chip_change = amount - u.round_bet # I need this so that, I can increment pot with old round_bet
                u.round_bet = amount
                u.chips -= chip_change
                u.save

                self.all_in = true if u.chips == 0
                self.pot += chip_change
                self.highest_bet_for_phase = amount

                # next_turn(blinds)
            end
        when 'allin'
            chip_change = max_raise_level - u.round_bet
            u.round_bet = max_raise_level
            u.chips -= chip_change
            u.save

            self.all_in = true
            self.pot += chip_change
            self.highest_bet_for_phase = max_raise_level
            # u.make_move('raise', max_raise_level)
        end

        ActionCable.server.broadcast("game_#{game.id}", { type: "new_move", turn_index: turn_index, command: command, moved_user: GameUserSerializer.new(u).serializable_hash, }) if !blinds 

        next_turn(blinds)

        if check_if_over
            end_game_by_fold
        elsif phase_finished?
            initiate_next_phase
        end

        # if !blinds && self.is_playing
        #     sleep 0.80
        #     # what do I actually need to send here?
        #     # new turn? 
        #     # I need new pot
        #     # new phase
        #     ActionCable.server.broadcast("game_#{game.id}", { type: "update_game_after_move", game: game })
        # end
        
        self.save
        
        make_marley_move if !blinds && self.is_playing
    end

    def make_marley_move
        # binding.pry
        if self.game.id == 1
            puts turn
            u = turn
            if u && u.id == 1
                sleep 1
                u.call_or_check
            end
        end
    end

    def max_raise_level # these two should be computated in the beginning of the phase?
        max = 0
        player_ids.each_with_index do |id, index|
            player = User.find(id)
            next if !player.playing
            player_max = player.chips + player.round_bet
            max = player_max if player_max < max || index == 0
        end
        max
    end

    def can_players_afford?(amount) # this should be in the beginning of the phase?
        player_ids.each do |id|
            player = User.find(id)
            return false if (player.chips < amount - player.round_bet) && player.playing
        end
    end

    def initiate_next_phase
        if all_in || self.phase == RIVER #If someone is all in or phase RIVER go to showdown
            self.phase = RIVER
            self.save
            showdown
        else
            self.phase += 1
            start_betting_round
            # new phase, 
            # new community cards
            # new pot
            # new turn

            # also need to update each player's card rank
            sleep 0.80
            ActionCable.server.broadcast("game_#{game.id}", { type: "next_betting_phase", access_community_cards: access_community_cards, pot: self.pot, phase: self.phase, turn_as_json: turn_as_json, seats_current_hand: seats_current_hand })
            # make_marley_move
        end
    end

    def seats_current_hand
        self.seats.map{|id| id ? User.find(id).current_hand : nil}
    end

    def showdown
        best_hands = []
        best_indices = []
        best_players = []

        seats.each_with_index do |id, index|
            next if id == nil 
            
        # active_player_ids.each_with_index do |id, index|
            player = User.find(id)
            next if !player.playing
            hand = PokerHand.new(player.cards + " " + self.community_cards)
            if best_hands == [] || hand == best_hands[0]
                best_hands << hand
                best_indices << index
                best_players << player
            elsif hand > best_hands[0]
                best_hands = [hand]
                best_indices = [index]
                best_players = [player]
            end
        end
        
        split = self.pot / best_players.count
        best_ids = {} # so we can return ids that won in a hash, for client to put sound
        best_players.each do |player|
            best_ids[player.id] = true
            player.chips += split
            player.winnings = split
            player.save
        end

        self.phase = 4
        self.is_playing = false
        self.save
        # I need to return startable, winner_indices, winnings
        sleep 0.80
        ActionCable.server.broadcast("game_#{self.game.id}", { 
                type: "game_end_by_showdown",
                access_community_cards: access_community_cards,
                startable: self.game.startable,
                winner_indices: best_indices,
                winnings: split,
                winner_ids: best_ids,
                seats_current_hand: seats_current_hand 
            })
    end


    def end_game_by_fold
        index = self.seats.index{|p| User.find(p).playing }
        last_player = User.find(self.seats[index])

        # last_player = User.find(self.active_player_ids[0])
        last_player.chips += self.pot
        last_player.winnings = self.pot
        last_player.save

        self.is_playing = false
        self.save

        sleep 0.80
        ActionCable.server.broadcast("game_#{self.game.id}", { 
                type: "game_end_by_fold",
                startable: self.game.startable,
                winner_index: index,
                winnings: self.pot,
                winner_ids: { last_player.id => true } 
            }) 
    end
end
