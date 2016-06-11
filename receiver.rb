#!/usr/bin/env ruby

require 'sinatra'
require 'sinatra'
require 'json'

post '/' do
  message = JSON.parse(request.body.read)
  puts "received: #{message}"
  content_type 'application/json'
  { message: "echo: #{message['message']}", format: 'text' }.to_json
end
