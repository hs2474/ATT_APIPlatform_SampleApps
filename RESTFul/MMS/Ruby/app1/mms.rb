#!/usr/bin/ruby
# Licensed by AT&T under 'Software Development Kit Tools Agreement.' 2013
# TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION: http://developer.att.com/sdk_agreement/
# Copyright 2013 AT&T Intellectual Property. All rights reserved. http://developer.att.com
# For more information contact developer.support@att.com

require 'rubygems'
require 'json'
require 'rest_client'
require 'sinatra'
require 'sinatra/config_file'
require 'base64'
require 'cgi'
require 'att_mms_service'

#include namespace
include AttCloudServices::MMS

enable :sessions

config_file 'config.yml'

set :port, settings.port
set :protection, :except => :frame_options

SCOPE = 'MMS'
ATTACH_DIR=File.join(File.expand_path(File.dirname(__FILE__)), "public/attachments")

RestClient.proxy = settings.proxy

#setup our mms service for the application
configure do
  Service = MmsService.new(settings.FQDN,
                           settings.api_key,
                           settings.secret_key,
                           SCOPE,
                           :tokens_file => settings.tokens_file)
end

before do 
  Dir.mkdir(settings.momms_image_dir) unless File.directory?(settings.momms_image_dir)
  Dir.mkdir(settings.momms_data_dir) unless File.directory?(settings.momms_data_dir)
  display_images
  drop_down_list
  @status_listener = load_file "#{settings.status_file}"
end

get '/' do
  session[:mms_id] = nil
  erb :mms
end

post '/statusListener' do
  handle_inbound "#{settings.status_file}"
end

post '/refreshStatus' do
  erb :mms
end

post '/sendMms' do
  begin
    session[:mms1_address] = params[:address]
    session[:mms1_subject] = params[:subject]
    session[:selected_file] = params[:attachment]

    notify = false
    notify = true if params[:chkGetOnlineStatus]

    if params[:attachment] and params[:attachment].empty?
      attachment = nil
    else
      attachment  = File.join(ATTACH_DIR, params[:attachment])
    end

    response  = Service.sendMms(params[:address], params[:subject], attachment, notify)

    @mms_id = JSON.parse(response)['outboundMessageResponse']['messageId']
    @mms_url = JSON.parse(response)['outboundMessageResponse']['resourceReference']['resourceURL']
    session[:mms_id] = @mms_id unless notify

  rescue RestClient::Exception => e
      @send_error = e.response 
  rescue => e
      @send_error = e.message
  ensure
    return erb :mms
  end
end

post '/getStatus' do
  begin 
    session[:mms_id] = params[:mmsId]

    response = Service.getDeliveryStatus(session[:mms_id])

    delivery_info_list = JSON.parse(response)['DeliveryInfoList']
    @delivery_info = delivery_info_list['DeliveryInfo']
    @mms_url = delivery_info_list['ResourceUrl']
  rescue => e
    @delivery_error = e.response
  ensure
    return erb :mms
  end
end

# use this URL to clear token file
get '/clear' do
  File.delete settings.tokens_file if File.exists? settings.tokens_file
  redirect '/'
end

def drop_down_list
  @attachments = Array.new
  #insert a blank attachment
  @attachments << ""
  Dir.entries(ATTACH_DIR).sort.each do |x|
    @attachments.push x unless x.match /\A\.+/
  end
end

def load_attachment filename
  return File.read(File.join(ATTACH_DIR,filename))
end

# # # # # # # # #
# MMS LISTENER  #
# # # # # # # # #
post '/mmslistener' do
  mms_listener
end

def display_images
  data = get_image_data

  @images_total = data[:image_count]
  @images_list = data[:image_list]
end

def mms_listener
  input   = request.env["rack.input"].read
  random  = rand(10000000).to_s
  Service.handleInput(input) do |sender, date, text, type, image|
    File.open("#{settings.momms_image_dir}/#{random}.#{type}", 'w') { |f| f.puts image }
    File.open("#{settings.momms_data_dir}/#{random}.#{type}.txt", 'w') { |f| f.puts sender, date, text } 
  end
end

def get_image_data
  images = Array.new

  Dir.entries(settings.momms_image_dir).each do |entry|
    rel_path = File.join(settings.momms_image_dir, entry)
    if File.file? rel_path
      data = File.join(settings.momms_data_dir, entry + ".txt");
      if File.exists? data
        File.open(data, "r") do |f|
          images.push({:path => rel_path.sub("public/",""), :senderAddress => f.gets.strip, :date => f.gets.strip, :text => f.gets.strip}) 
        end
      end
    end
  end
  return {:image_count => images.length, :image_list => images}
end

def load_file(file)
  data = Array.new
  if File.exists? file then
    File.open(file, 'r') do |f|
      begin
        f.flock(File::LOCK_EX)
        f.each_line {|line| data << JSON.parse(line)}
      ensure
        f.flock(File::LOCK_UN)
      end
    end
  end
  data
end

def handle_inbound(file)
  input = request.env["rack.input"].read

  if !File.exists? file
    File.new(file, 'w')
  end

  contents = File.readlines(file)

  File.open(file, 'w') do |f|
    begin
      f.flock(File::LOCK_EX)
      #remove the first line if we're over limit
      if contents.size > settings.listener_limit - 1 
        offset = 1
      else
        offset = 0
      end
      f.puts contents[offset, contents.size] 
      f.puts JSON.parse(input).to_json
    ensure
      f.flock(File::LOCK_UN)
    end
  end
end
