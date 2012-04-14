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
#    puts data.to_json if data['op'] == 'moves'
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

        my_neighbors = p['neighbors'].select { |n| @info['holds'][n[0]][0] == @me['seq'] }
        my_planet[:my_neighbors] = my_neighbors

        @my_planets[ind] = my_planet
      end
    end

    # Compute rearness and path of my rear planets iteratively
    my_planets = @my_planets
    left_planets = @my_planets.select { |id, p| p[:rearness].nil? }
    while left_planets.size > 0
      left_planets.each do |id, p|
        neighbors = @map['planets'][id]['neighbors'].reject { |n| my_planets[n[0]][:rearness].nil? }
        next if neighbors.size == 0 # Very important! Used to be a bug!!!
        nearest_neighbor = neighbors.map { |n| [ n[0], my_planets[n[0]][:rearness] + n[1] ] }.min_by { |n| n[1] }
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
#	puts @my_planets

    moves = []

    # Front line planets: 1. defence; 2. attack enemy planets
    # Defence

    # Compute spare forces for each planet
    spare_forces = {}
    @my_planets.each do |id, p|
      if p[:rearness] == 0
        spare_forces[id] = spare_force_on_first_invasion(id)
      else
        rate = 0.8
        spare_forces[id] = [(@info['holds'][id][1] * rate).to_i, nil]
      end
    end

    @my_planets.select { |id, p| p[:rearness] == 0 }.each do |id, p|
      q = @map['planets'][id]

      if spare_forces[id][0] < 0
        reinforce_moves = []
        reinforce = 0
        success_flag = false
      # Get help from nearby rear planets or front line planets that have spare force
        @my_planets[id][:my_neighbors].select { |n| spare_forces[n[0]][0] > 0 && n[1] <= spare_forces[id][1] }.sort_by { |n| n[1] }.each do |n|
          send = spare_forces[n[0]][0]
          reinforce_moves << [send, n[0], id]

          reinforce += send
          if reinforce > spare_forces[id][0].abs
            success_flag = true
            break
          end
        end

        if success_flag
          # Send reinforcements
          moves += reinforce_moves

          # Mark them as processed
          print "Reinforcements: planet <- #{id}"
          reinforce_moves.each do |m|
            print " #{m[1]}"
            @my_planets[m[1]][:processed?] = true
          end
          puts
        elsif spare_forces[id][1] == 1
          # Retreat
          spare_forces[id][0] = @info['holds'][id][1]
          @my_planets[id][:retreat?] = true
        end
      end
    end

    # Attack
    @my_planets.select { |id, p| p[:rearness] == 0 && ! @my_planets[id][:processed?] }.each do |id, p|
      if spare_forces[id][0] > 0
        attack_moves = attack(id, p, spare_forces)
        moves += attack_moves
      end
    end

    # Rear planets: to support planets on the front line
    # Support
    @my_planets.select { |id, p| p[:rearness] > 0 && ! @my_planets[id][:processed?] }.each do |id, p|
      q = @map['planets'][id]

      count = @info['holds'][id][1]
      send = count - ((q['max'] - q['cos']) / q['res']).to_i
      send = [send, 0].max
      moves << [send, id, p[:targets]] if send > 0
    end

    # Retreat the planet that was marked as 'retreat' previously
    @my_planets.select { |id, p| p[:rearness] == 0 && @my_planets[id][:retreat?] && ! @my_planets[id][:processed?] }.each do |id, p|
      targets = @my_planets[id][:my_neighbors].sort_by { |n| @my_planets[n[0]][:rearness] }
      if ! targets.empty?
        t = targets.last
        send = spare_forces[id][0]
        moves << [send, id, t[0]]
        @my_planets[id][:processed?] = true
        puts "Retreat: planet #{id} -> #{t[0]}"
      else
        attack_moves = attack(id, p, spare_forces)
        if ! attack_moves.empty?
          moves += attack_moves
          puts "Transport: planet #{id} -> #{attack_moves.first[2]}"
        end
      end
    end

    cmd_moves moves
  end


  # Forcast condition of planet id after given rounds
  def condition_after_given_rounds(id, round)
    # Current condition (planet_side, planet_count)
    planet_side, planet_count = @info['holds'][id]

    # Gather all incoming moves
    arrives = @info['moves'].select { |m| m[2] == id }

    # Simulate wars happend during the given rounds
    (1..round).each do |rnd|
      # Production stage
      planet_count = planet_production(id, planet_count)

      # War stage
      cur_arrives = arrives.select { |m| m[4] == rnd }
      planet_side, planet_count = planet_fight(id, planet_side, planet_count, cur_arrives)
    end

    return [planet_side, planet_count]
  end


  def spare_force_on_first_invasion(id)
    q = @map['planets'][id]

    # Gather all invasions
    invasions = @info['moves'].select { |m| m[0] != @me['seq'] && m[2] == id }.group_by { |m| m[4] }
    if invasions.empty?
      spare_force = @info['holds'][id][1] - 1
      spare_force = [spare_force, 0].max
      return [spare_force, nil]
    end

    nearest_round = invasions.keys.min # First wave

    # Enemy forces in round nearest_round
    enemy_force = invasions[nearest_round].map { |m| m[3] }.inject(0, :+)

    # My reinforcements in round nearest_round
    my_force = @info['moves'].select { |m| m[0] == @me['seq'] && m[2] == id && m[4] == nearest_round }.map { |m| m[3] }.inject(0, :+)

    # Condition just before round nearest_round
    side, count = condition_after_given_rounds(id, nearest_round-1)

    spare_force = count - (( (enemy_force-my_force)/q['def'] - q['cos'] ) / q['res']).to_i
    if spare_force > 0
      nearest_round.times do |i|
        spare_force = ( (spare_force - q['cos']) / q['res'] ).to_i
      end
      spare_force = [spare_force, 0].max
    end

    return [spare_force, nearest_round]
  end

  def planet_production(id, planet_count)
    # Properties of the planet, i.e. q['def'], q['res'], q['cos'], q['max']
    q = @map['planets'][id]
    new_count = (planet_count * q['res'] + q['cos']).to_i
    if planet_count < q['max']
      planet_count = [new_count, q['max']].min
    elsif new_count < planet_count
      planet_count = new_count
    end
    return planet_count
  end

  def planet_fight(id, planet_side, planet_count, cur_arrives)
    q = @map['planets'][id]
    cur_arrives.each do |m|
      side, count = m[0], m[3]
      if side == planet_side
        planet_count += count
      else
        planet_count *= q['def']
        if planet_count == count
          planet_side, planet_count = nil, 0 # No one lives after the fight..
        elsif planet_count < count
          planet_side = side
          planet_count = count - ( planet_count**2 / count.to_f ).to_i
        else
          planet_count -= ( count**2 / planet_count.to_f ).to_i
          planet_count = (planet_count / q['def']).to_i
        end
      end
    end
    return [planet_side, planet_count]
  end

  def attack(id, p, spare_forces)
    moves = []

    nil_targets = []
    targets = []
    p[:targets].each do |t|
      q = @map['planets'][t[0]]

      side, count = condition_after_given_rounds(t[0], t[1])
      if side.nil? || side == @me['seq'] # It's empty or has been occupied by myself by then
        nil_targets << [t[0]]
      elsif spare_forces[id][0] > count*q['def']
        targets << [ t[0], count * q['def']**2 / spare_forces[id][0].to_f ]
      end
    end

    if ! nil_targets.empty? # Evenly send force to nil planets
      send = (spare_forces[id][0] / nil_targets.size).to_i
      nil_targets.each do |t|
        moves << [send, id, t[0]]
        @my_planets[id][:processed?] = true
      end
    elsif ! targets.empty?
      target = targets.min_by { |t| t[1] }
      send = spare_forces[id][0]
      moves << [send, id, target[0]]
      @my_planets[id][:processed?] = true
    end

    return moves
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
