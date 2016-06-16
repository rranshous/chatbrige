#!/usr/bin/env ruby

require 'sinatra'
require 'json'
require 'docker'
require 'uri'
require 'pry'

$stdout.sync = true

DOCKER_IMAGE_NAME = ENV['DOCKER_IMAGE_NAME']
puts "docker_image_name: #{DOCKER_IMAGE_NAME}"

def log msg
  puts msg
  msg
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
  def self.from_subscription subscription
    new subscription.api_key,
        subscription.room,
        subscription.sender,
        subscription.target,
        subscription.poll_delay
  end

  def self.from_config config
    new config['api_key'],
        config['room'],
        config['sender'],
        config['target'],
        config['poll_delay']
  end

  def self.all_active
    Docker::Container.all.map do |container|
      container_labels = container.json["Config"]["Labels"]
      if container_labels['app.name'] == "chatbridge_sender"
        from_config Hash[container_labels.to_a.map do |(k,v)|
          if k.start_with? 'bridge_manager.config.'
            [k.gsub('bridge_manager.config.',''), v]
          else
            nil
          end
        end]
      else
        nil
      end
    end.compact
  end

  attr_reader :api_key, :room, :sender, :target, :poll_delay

  def initialize api_key, room, sender, target, poll_delay
    @api_key, @room, @sender, @target = api_key, room, sender, target
    @poll_delay = poll_delay
  end

  def start
    start_container
  end

  def stop
    kill_and_delete_container
  end

  def is_running?
    container = find_container
    if container
      container.json["State"]["Running"]
    else
      false
    end
  end

  def recent_logs
    container_logs
  end

  private

  def find_container
    Docker::Container.all.each do |container|
      container_labels = container.json["Config"]["Labels"]
      if container_labels == labels
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
      'RestartPolicy' => { 'Name': 'always' },
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

  def container_logs
    container = find_container
    return nil unless container
    container.streaming_logs(stdout: 1, stderr: 1, tail: 100, follow: 0).to_s
  end

  def kill_and_delete_container
    container = find_container
    return false unless container
    container.kill
    container.delete
    true
  end

  def labels
    {
      'app.name' => 'chatbridge_sender',
      'bridge_manager.config.room' => @room.to_s,
      'bridge_manager.config.api_key' => @api_key.to_s,
      'bridge_manager.config.sender' => @sender.to_s,
      'bridge_manager.config.target' => @target.to_s,
      'bridge_manager.config.poll_delay' => @poll_delay.to_s,
    }
  end
end

post "/remove_subscription" do
  data_in = JSON.parse(request.body.read)
  log "data_in: #{data_in}"
  subscription = Subscription.from_options(data_in)
  log "subscription: #{subscription}"
  bridge = BridgeProcess.from_subscription subscription
  bridge.stop
  forward_url = "/check_subscription?#{URI.encode_www_form(subscription.to_h)}"
  redirect forward_url, 303
end

post "/remove_subscription/:bridge" do |bridge_config_encoded|
  data_in = JSON.parse(Base64.urlsafe_decode64(bridge_config_encoded))
  log "data_in: #{data_in}"
  subscription = Subscription.from_options(data_in)
  log "subscription: #{subscription}"
  bridge = BridgeProcess.from_subscription subscription
  bridge.stop
  forward_url = "/check_subscription?#{URI.encode_www_form(subscription.to_h)}"
  redirect forward_url, 303
end

post "/add_subscription/form_encoded" do
  puts "params: #{params}"
  subscription = Subscription.from_options(params)
  log "subscription: #{subscription}"
  subscription.room.empty? and
    log "failed req: missing room" and halt 400, "missing room"
  subscription.sender.empty? and
    log "failed req: missing sender" and halt 400, "missing sender"
  subscription.api_key.empty? and
    log "failed req: missing api_key" and halt 400, "missing api_key"
  subscription.target.empty? and
    log "failed req: missing target" and halt 400, "missing target"
  bridge = BridgeProcess.from_subscription subscription
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
  bridge = BridgeProcess.from_subscription subscription
  running = bridge.is_running?
  log "running?: #{running}"
  content_type :json
  { running: running }.to_json
end

get '/subscription_logs' do
  subscription = Subscription.from_options(params)
  log "subscription: #{subscription}"
  bridge = BridgeProcess.from_subscription subscription
  running = bridge.is_running?
  log "running?: #{running}"
  content_type :text
  bridge.recent_logs
end

get "/" do
  bridges = BridgeProcess.all_active
  @data = {
    bridges: bridges.map{ |bridge|
      OpenStruct.new({
        api_key_snippet: bridge.api_key[-5..-1],
        api_key: bridge.api_key,
        room: bridge.room,
        sender: bridge.sender,
        target: bridge.target,
        poll_delay: bridge.poll_delay,
        encoded_config: Base64.urlsafe_encode64({
          api_key: bridge.api_key,
          room: bridge.room,
          sender: bridge.sender,
          target: bridge.target,
          poll_delay: bridge.poll_delay
        }.to_json)
      })
    }
  }
  erb :'index.html'
end

