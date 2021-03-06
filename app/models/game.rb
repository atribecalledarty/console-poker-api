class Game < ApplicationRecord
    belongs_to :room
    has_many :users
    has_many :rounds

    #seats 
    #big_blind

    def as_json(options = {})
        super(only: [:id, :big_blind], methods: [:active_round, :seats_as_users, :startable])
    end 

    def sit(index, u)
        index = self.seats.find_index(nil) if !index # Find first seat avail if no index provided
        if !self.seats[index]
            self.users << u
            self.seats[index] = u.id
            self.save
        end 
    end

    def unsit(u)
        index = nil
        index = self.seats.find_index(u.id)
        self.seats[index] = nil if index # if user was found
        self.users.delete(u)
        self.save
        index # need to return so that in games#action, I can return the index that is empty 
    end

    def seats_as_users
        self.seats.map{|id| GameUserSerializer.new(User.find(id)).serializable_hash if id}
    end
    
    def active_round
        self.rounds.last
    end

    def find_new_sbi # determines next small_blind_index
        if r = self.active_round
            new_index = r.small_blind_index
            while !self.seats[new_index] || new_index == r.small_blind_index
                new_index = (new_index + 1) % 8
            end
        else
            new_index = 0
            while !self.seats[new_index]
                new_index += 1
            end
        end
        new_index
    end

    def start
        new_round = self.rounds.create(small_blind_index: find_new_sbi, big_blind: self.big_blind)
        # self.save # Need to make sure to save before starting, because round needs to know the game it belongs to.

        new_round.start
        self.save
    end

    def startable
        # self.users.count > 1 && !self.active_round && self.players_have_enough_money?)
        # (self.users.count > 1 && !self.active_round && self.players_have_enough_money?)  || (self.users.count > 1 && !self.active_round.is_playing && self.players_have_enough_money?)) ? true : false
        (self.users.count > 1 && (!self.active_round || !self.active_round.is_playing) && self.players_have_enough_money?) ? true : false
    end

    def players_have_enough_money?
        self.users.each {|u| return false if u.chips < self.big_blind }
        true
    end
end
