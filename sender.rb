#!/usr/bin/env ruby

require 'hipchat'
require 'docker'
require 'localmemcache'
require 'json'

$stdout.sync = true

def log msg
  puts msg
end

module Limiter
  def self.with_hipchat_backoff &blk
    Reattempter.reattempt(3, 60, HipChat::TooManyRequests) do
      blk.call
    end
  end
end

module Reattempter
  def self.reattempt times, sleep_time=0, to_catch=Exception, &blk
    begin
      blk.call
    rescue to_catch => ex
      log "exception caught: #{ex}"
      if times > 0
        log "retrying"
        if sleep_time > 0
          log "sleeping: #{sleep_time}"
          sleep sleep_time
        end
        times -= 1
        retry
      else
        log "reraising"
        raise
      end
    end
  end
end

class Poller

  attr_reader :last_id

  def initialize hipchat_client, room_name, last_id=nil, sleep_time=1
    @hipchat_client = hipchat_client
    @sleep_time = sleep_time
    @room_name = room_name
    @last_id = last_id || rooms_last_id
    @last_id_change_callback = nil
  end

  def poll &blk
    loop do
      log "polling: #{@room_name}"
      Limiter.with_hipchat_backoff do
        new_messages(@room_name).each do |message|
          blk.call message
          self.last_id = message['id']
        end
        sleep @sleep_time
      end
    end
  end

  def rooms_last_id
    log "getting last_id from #{@room_name}"
    last_id = nil
    Limiter.with_hipchat_backoff do
      last_id = (JSON.parse(
                 @hipchat_client[@room_name]
                  .history(:'max-results'=>10))['items']
                  .select { |m| m['type'] == 'message' }
                  .last || {})['id']
      log "last_id: #{last_id}"
    end
    last_id
  end

  def on_last_id_change &blk
    @last_id_change_callback = blk
  end

  protected

  def new_messages room_name
    log "polling for new messages"
    messages = JSON.parse(
                @hipchat_client[room_name]
                 .recent_history(:'not-before'=>@last_id))['items']
                 .select { |m| m['type'] == 'message' }
    messages = messages[1..-1] || []
    log "messages found #{messages.length}"
    messages
  end


  def last_id= value
    log "setting last_id: #{value}"
    @last_id = value
    if @last_id_change_callback
      log "calling callback"
      @last_id_change_callback.call @last_id
    end
  end
end

class Pusher
  def initialize target_href
    @target_href = target_href
  end

  def push message
    log "pushing message to target"
    r = nil
    Reattempter.reattempt(3,5) do
      r = HTTParty.post(@target_href, body: message.to_json)
      unless (200..299).include? r.code
        log "status code not good: #{r.code}"
        raise "Failing HTTP response code: #{r.code}"
      end
    end
    log "done pushing"
    log "response: #{r.parsed_response}"
    r.parsed_response
  end

  protected

end

class State
  def initialize path
    log "loading or creating state: #{path}"
    @store = LocalMemCache.new(:filename => path)
    log "state loaded"
  end

  def [] key
    JSON.load(@store[key])
  end

  def []= key, value
    log "updating state: #{key} => #{value}"
    @store[key] = value.to_json
  end
end


STATE_DATA_DIR = ENV['STATE_DATA_DIR']
HIPCHAT_ROOM_NAME = ENV['HIPCHAT_ROOM_NAME']
HIPCHAT_API_KEY = ENV['HIPCHAT_API_KEY']
HIPCHAT_SENDER = ENV['HIPCHAT_SENDER']
MESSAGE_TARGET = ENV['MESSAGE_TARGET']
POLL_DELAY = (ENV['POLL_DELAY'] || 5).to_i
log "room: #{HIPCHAT_ROOM_NAME}"
log "api_key: ...#{HIPCHAT_API_KEY[-5..-1]}"
log "sender: #{HIPCHAT_SENDER}"
log "target: #{MESSAGE_TARGET}"
log "state dir: #{STATE_DATA_DIR}"
log "getting last message"

state = State.new File.join(STATE_DATA_DIR, 'sender.lmc')

hipchat_client = HipChat::Client.new(HIPCHAT_API_KEY, :api_version => 'v2')
pusher = Pusher.new(MESSAGE_TARGET)
log "starting poller"
log "seeding poller at last_id: #{state['last_id']}" if state['last_id']
poller = Poller.new(hipchat_client, HIPCHAT_ROOM_NAME, state['last_id'], POLL_DELAY)
poller.on_last_id_change { |last_id| state['last_id'] = last_id }
poller.poll do |message|
  begin
    log "going to push message: #{message['message']}"
    response_data = pusher.push message
    log "going to send response: #{response_data}"
    log "message: #{response_data['message']}"
    msg, format = response_data['message'], response_data['format']
    hipchat_client[HIPCHAT_ROOM_NAME].send(HIPCHAT_SENDER, msg,
                                           'message_format' => format)
  rescue Exception => ex
    log "Toplvl Exception: #{ex}"
    raise
  end
end
