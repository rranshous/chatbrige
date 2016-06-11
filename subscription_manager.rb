#!/usr/bin/env ruby

require 'sinatra'

module Subscription
  POSSIBLE_OPTIONS = %w{ api_key room sender target  }
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
    Docker::Container.create({
      'Image' => image.id,
      'Env' => []
    })
  end
end

post "/add_subscription" do
  data_in = JSON.parse(request.body.read)
  subscription = Subscription.from_options(data_in)
  bridge = BridgeProcess.for_subscription subscription
  started = bridge.start

  content_type :json
  { started: started }
end
