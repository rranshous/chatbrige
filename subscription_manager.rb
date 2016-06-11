#!/usr/bin/env ruby

require 'sinatra'
require 'json'
require 'docker'
require 'pry'

$stdout.sync = true

DOCKER_IMAGE_NAME = ENV['DOCKER_IMAGE_NAME']

def log msg
  puts msg
end

module Subscription
  POSSIBLE_OPTIONS = %w{ api_key room sender target  }
  def self.from_options sub_options
    OpenStruct.new(Hash[
      POSSIBLE_OPTIONS.map { |o| [o, sub_options[o]] }
    ])
  end
end

class BridgeProcess
  def self.for_subscription subscription
    new subscription.api_key,
        subscription.room,
        subscription.sender,
        subscription.target
  end

  def initialize api_key, room, sender, target
    @api_key, @room, @sender, @target = api_key, room, sender, target
  end

  def start
    start_container
  end

  private
  def start_container
    image = Docker::Image.create('fromImage' => DOCKER_IMAGE_NAME)
    log "creating container: #{@room} => #{@target}"
    if is_running?
      log "already running, not starting"
      return false
    end
    container = Docker::Container.create({
      'Image' => image.id,
      'Env' => [
        "HIPCHAT_ROOM_NAME=#{@room}",
        "HIPCHAT_API_KEY=#{@api_key}",
        "HIPCHAT_SENDER=#{@sender}",
        "MESSAGE_TARGET=#{@target}"
      ],
      'Labels' => labels
    })
    log "created container: #{container.id}"
    log "starting container"
    container.start
    log "container started"
    true
  end

  def labels
    {
      'hipchat_room' => @room,
      'hipchat_api_key' => @api_key,
      'hipchat_sender' => @sender,
      'message_target' => @target
    }
  end

  def is_running?
    # check all the containers for a container whos labels match ours
    # and than check if it's running
    Docker::Container.all.each do |container|
      container_json = container.json
      if container_json["Config"]["Labels"] == labels
        return container_json["State"]["Running"]
      end
    end
    false
  end
end

post "/add_subscription" do
  data_in = JSON.parse(request.body.read)
  subscription = Subscription.from_options(data_in)
  bridge = BridgeProcess.for_subscription subscription
  started = bridge.start

  content_type :json
  { started: started }.to_json
end
