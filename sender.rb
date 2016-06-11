#!/usr/bin/env ruby

require 'hipchat'
require 'docker'

def log msg
  puts msg
end

class Poller

  def initialize hipchat_client, sleep_time=5
    @hipchat_client = hipchat_client
    @sleep_time = sleep_time
    @last_id = nil
  end

  def poll room_name, &blk
    loop do
      begin
        log "polling"
        new_messages.each do |message|
          blk.call message
          self.last_id = message['id']
        end
        sleep @sleep_time
      end
    end
  end

  def last_id
    puts "getting last_id"
    @last_id ||= JSON.parse(
                  @hipchat_client[ROOM_NAME]
                   .history(:'max-results'=>1))['items']
                   .select { |m| m['type'] == 'message' }
                   .last['id']
    puts "last_id: #{@last_id}"
    @last_id
  end

  protected

  def new_messages
    log "polling for new messages"
    messages = JSON.parse(
                @hipchat_client[ROOM_NAME]
                 .recent_history(:'not-before'=>last_id))['items']
                 .select { |m| m['type'] == 'message' }
    messages = messages[1..-1] || []
    puts "messages found #{messages.length}"
    messages
  end


  def last_id= value
    puts "setting last_id: #{value}"
    @last_id = value
  end
end

class Pusher
  def initialize target_href
    @target_href = target_href
  end

  def push message
    log "pushing message to target"
    r = nil
    reattempt(3,5) do
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

  def reattempt times, sleep_time=0, &blk
    begin
      blk.call
    rescue Exception => ex
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


ROOM_NAME = ENV['HIPCHAT_ROOM_NAME']
API_KEY = ENV['API_KEY']
HIPCHAT_SENDER = ENV['HIPCHAT_SENDER']
MESSAGE_TARGET = ENV['MESSAGE_TARGET']
log "room: #{ROOM_NAME}"
log "api_key: #{API_KEY[-5..-1]}"
log "sender: #{HIPCHAT_SENDER}"
log "target: #{MESSAGE_TARGET}"
log "getting last message"

hipchat_client = HipChat::Client.new(API_KEY, :api_version => 'v2')
pusher = Pusher.new(MESSAGE_TARGET)
log "starting poller"
Poller.new(hipchat_client).poll(ROOM_NAME) do |message|
  begin
    log "going to push message: #{message['message']}"
    response_data = pusher.push message
    log "going to send response: #{response_data}"
    log "message: #{response_data['message']}"
    hipchat_client[ROOM_NAME].send(HIPCHAT_SENDER,
                                   response_data['message'],
                                   'message_format' => response_data['format'])
  rescue Exception => ex
    log "Toplvl Exception: #{ex}"
    raise
  end
end
