require 'json'
require 'net/http'

SERVER = "localhost"
PORT = 9999
ROOM = 0

class PlanetAI
  def initialize
    @conn = Net::HTTP.new(SERVER, PORT)
    @room = ROOM
    @last_round_id = -1
  end
  
  def cmd(cmd, data={})
    data['op'] = cmd
    data['room'] = @room
#    puts data.to_json
    request = Net::HTTP::Post.new("/cmd")
    request.set_form_data(data)
    response = @conn.request(request)
    result = JSON.parse(response.body)
  end

  def cmd_add
    @me = cmd "add", name: "ai_xiaoyong", side: "ruby"
  end

  def cmd_map
    @map = cmd "map"

    # Add neighborhood information to each planet
    @map['planets'].each_with_index do | p, ind |
      routes = @map['routes'].select { |r| r[0] == ind }
      p['neighbors'] = routes.map { |r| r[1..2] }
      # neighbors[0]: id of neighbor planet
      # neighbors[1]: distance to the neighbor planet
    end
	puts @map
  end

  def cmd_info
    @info = cmd "info"
  end

  def cmd_moves moves
    cmd "moves", 'id' => @me['id'], 'moves' => moves.to_json
  end

  # Helper methods
  # See whether the planet is on the front line or at the rear by ownership of nearby planets
  def update_map
    @my_planets = {}

    @map['planets'].each_with_index do | p, ind |
      # Check whether it is owned by me
      if @info['holds'][ind][0] == @me['seq']
        # my_planet:
        # - targets: enemy planet candidates to attack if a front line planet, or next planet of the shortest path to the nearest front line planet if a rear planet
        # - rearness: how far away from the front line, 0 for planet on the front line
        my_planet = {}

        # Check whether on the front line
        targets = p['neighbors'].select { |n| @info['holds'][n[0]][0] != @me['seq'] }
        if targets.size > 0 # On the front line
          my_planet[:targets] = targets
          my_planet[:rearness] = 0
        end

        @my_planets[ind] = my_planet
      end
    end

    # Compute rearness and path of my rear planets iteratively
    my_planets = @my_planets
    left_planets = @my_planets.select { |id, p| p[:rearness].nil? }
    while left_planets.size > 0
      left_planets.each do |id, p|
        nearest_neighbors = @map['planets'][id]['neighbors'].reject { |n| my_planets[n[0]][:rearness].nil? }
        next if nearest_neighbors.size == 0 # Very important! Used to be a bug!!!
        nearest_neighbor = nearest_neighbors.map { |n| [ n[0], my_planets[n[0]][:rearness] + n[1] ] }.min { |a, b| a[1] <=> b[1] }
        @my_planets[id][:targets] = nearest_neighbor[0]
        @my_planets[id][:rearness] = nearest_neighbor[1]
      end

      my_planets = @my_planets
      left_planets = @my_planets.select { |id, p| p[:rearness].nil? }
    end
  end


  def step
    if @info['round'] == @last_round_id
      return
    end
    @last_round_id = @info['round'] 

    update_map
	puts @my_planets

    moves = []
    @my_planets.each do |id, p|
      hold = @info['holds'][id][1]
      if p[:rearness] > 0
        # Rear planets: to support planets on the front line
        q = @map['planets'][id]
        sended = hold - ((q['max'] - q['cos']) / q['res']).to_i
        sended = [sended, 0].max
        moves << [sended, id, p[:targets]]

        # Update info
        @info['holds'][id][1] -= sended

      else
        # Front line planets: 1. defence; 2. attack enemy planets
        # Defence
        # Attack
        if p[:targets].size > 0
          sended = ((hold - 1) / p[:targets].size / 2).to_i
          p[:targets].each do |t|
            moves << [sended, id, t[0]]
            @info['holds'][id][1] -= sended
          end
        end
      end
    end

    cmd_moves moves
  end

end


ai = PlanetAI.new
ai.cmd_map
ai.cmd_add
while true
  sleep 0.3
  ai.cmd_info
  ai.step
#  puts ai.step
end
