#!/usr/bin/env ruby

require 'sinatra'
require 'json'
require 'docker'
require 'uri'
require 'pry'

$stdout.sync = true

DOCKER_IMAGE_NAME = ENV['DOCKER_IMAGE_NAME']

def log msg
  puts msg
end

module Subscription
  POSSIBLE_OPTIONS = %w{ api_key room sender target poll_delay }
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
        subscription.target,
        subscription.poll_delay
  end

  def initialize api_key, room, sender, target, poll_delay
    @api_key, @room, @sender, @target = api_key, room, sender, target
    @poll_delay = poll_delay
  end

  def start
    start_container
  end

  def stop
    kill_container
  end

  def is_running?
    container = find_container
    if container
      container.json["State"]["Running"]
    else
      false
    end
  end

  private

  def find_container
    Docker::Container.all.each do |container|
      if container.json["Config"]["Labels"] == labels
        return container
      end
    end
    nil
  end

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
        "MESSAGE_TARGET=#{@target}",
        "POLL_DELAY=#{@poll_delay}"
      ],
      'Labels' => labels
    })
    log "created container: #{container.id}"
    log "starting container"
    container.start
    log "container started"
    true
  end

  def kill_container
    container = find_container
    return false unless container
    container.kill
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
end

post "/add_subscription" do
  data_in = JSON.parse(request.body.read)
  subscription = Subscription.from_options(data_in)
  log "subscription: #{subscription}"
  subscription.room or
    (log "failed req: missing room" and halt 400, "missing room")
  subscription.sender or
    (log "failed req: missing sender" and halt 400, "missing sender")
  subscription.api_key or
    (log "failed req: missing api_key" and halt 400, "missing api_key")
  subscription.target or
    (log "failed req: missing target" and halt 400, "missing target")
  bridge = BridgeProcess.for_subscription subscription
  started = bridge.start
  forward_url = "/check_subscription?#{URI.encode_www_form(subscription.to_h)}"
  if started
    redirect forward_url, 201
  else
    redirect forward_url, 303
  end
end

get "/check_subscription" do
  subscription = Subscription.from_options(params)
  log "subscription: #{subscription}"
  bridge = BridgeProcess.for_subscription subscription
  running = bridge.is_running?
  log "running?: #{running}"
  content_type :json
  { running: running }.to_json
end

post "/remove_subscription" do
  data_in = JSON.parse(request.body.read)
  subscription = Subscription.from_options(data_in)
  log "subscription: #{subscription}"
  bridge = BridgeProcess.for_subscription subscription
  bridge.stop
  forward_url = "/check_subscription?#{URI.encode_www_form(subscription.to_h)}"
  redirect forward_url, 303
end
