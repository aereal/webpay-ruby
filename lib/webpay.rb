# Webpay Ruby bindings
# API spec at http://webpay.jp/api/spec
require 'cgi'
require 'set'
require 'rubygems'
require 'openssl'
require 'base64'

gem 'rest-client', '~> 1.4'
require 'rest_client'
require 'multi_json'

# Version
require 'webpay/version'

# API operations
require 'webpay/api_operations/create'
require 'webpay/api_operations/update'
require 'webpay/api_operations/delete'
require 'webpay/api_operations/list'

# Resources
require 'webpay/util'
require 'webpay/json'
require 'webpay/webpay_object'
require 'webpay/api_resource'
require 'webpay/singleton_api_resource'
require 'webpay/account'
require 'webpay/customer'
require 'webpay/invoice'
require 'webpay/invoice_item'
require 'webpay/charge'
require 'webpay/plan'
require 'webpay/coupon'
require 'webpay/token'
require 'webpay/event'
require 'webpay/transfer'

# Errors
require 'webpay/errors/webpay_error'
require 'webpay/errors/api_error'
require 'webpay/errors/api_connection_error'
require 'webpay/errors/card_error'
require 'webpay/errors/invalid_request_error'
require 'webpay/errors/authentication_error'

module Webpay
  @@ssl_bundle_path = File.join(File.dirname(__FILE__), 'data/ca-certificates.crt')
  @@api_key = nil
  @@api_base = 'https://api.webpay.jp/v1'
  @@verify_ssl_certs = true

  def self.api_url(url='')
    @@api_base + url
  end

  def self.api_key=(api_key)
    @@api_key = api_key
  end

  def self.api_key
    @@api_key
  end

  def self.api_base=(api_base)
    @@api_base = api_base
  end

  def self.api_base
    @@api_base
  end

  def self.verify_ssl_certs=(verify)
    @@verify_ssl_certs = verify
  end

  def self.verify_ssl_certs
    @@verify_ssl_certs
  end

  def self.request(method, url, api_key, params=nil, headers={})
    api_key ||= @@api_key
    raise AuthenticationError.new('No API key provided.  (HINT: set your API key using "Webpay.api_key = <API-KEY>".  You can generate API keys from the Webpay web interface.  See https://webpay.jp/api for details, or email support@webpay.jp if you have any questions.)') unless api_key

    if !verify_ssl_certs
      unless @no_verify
        $stderr.puts "WARNING: Running without SSL cert verification.  Execute 'Webpay.verify_ssl_certs = true' to enable verification."
        @no_verify = true
      end
      ssl_opts = { :verify_ssl => false }
    elsif !Util.file_readable(@@ssl_bundle_path)
      unless @no_bundle
        $stderr.puts "WARNING: Running without SSL cert verification because #{@@ssl_bundle_path} isn't readable"
        @no_bundle = true
      end
      ssl_opts = { :verify_ssl => false }
    else
      ssl_opts = {
        :verify_ssl => OpenSSL::SSL::VERIFY_PEER,
        :ssl_ca_file => @@ssl_bundle_path
      }
    end
    uname = (@@uname ||= RUBY_PLATFORM =~ /linux|darwin/i ? `uname -a 2>/dev/null`.strip : nil)
    lang_version = "#{RUBY_VERSION} p#{RUBY_PATCHLEVEL} (#{RUBY_RELEASE_DATE})"
    ua = {
      :bindings_version => Webpay::VERSION,
      :lang => 'ruby',
      :lang_version => lang_version,
      :platform => RUBY_PLATFORM,
      :publisher => 'webpay',
      :uname => uname
    }

    params = Util.objects_to_ids(params)
    url = self.api_url(url)
    case method.to_s.downcase.to_sym
    when :get, :head, :delete
      # Make params into GET parameters
      if params && params.count
        query_string = Util.flatten_params(params).collect{|p| "#{p[0]}=#{p[1]}"}.join('&')
        url += "?#{query_string}"
      end
      payload = nil
    else
      payload = params
    end

    begin
      headers = { :x_webpay_client_user_agent => Webpay::JSON.dump(ua) }.merge(headers)
    rescue => e
      headers = {
        :x_webpay_client_raw_user_agent => ua.inspect,
        :error => "#{e} (#{e.class})"
      }.merge(headers)
    end

    headers = {
      :user_agent => "Webpay/v1 RubyBindings/#{Webpay::VERSION}",
      :authorization => "Basic #{Base64.encode64(api_key)}"
    }.merge(headers)
    opts = {
      :method => method,
      :url => url,
      :headers => headers,
      :open_timeout => 30,
      :payload => payload,
      :timeout => 80
    }.merge(ssl_opts)

    begin
      response = execute_request(opts)
    rescue SocketError => e
      self.handle_restclient_error(e)
    rescue NoMethodError => e
      # Work around RestClient bug
      if e.message =~ /\WRequestFailed\W/
        e = APIConnectionError.new('Unexpected HTTP response code')
        self.handle_restclient_error(e)
      else
        raise
      end
    rescue RestClient::ExceptionWithResponse => e
      if rcode = e.http_code and rbody = e.http_body
        self.handle_api_error(rcode, rbody)
      else
        self.handle_restclient_error(e)
      end
    rescue RestClient::Exception, Errno::ECONNREFUSED => e
      self.handle_restclient_error(e)
    end

    rbody = response.body
    rcode = response.code
    begin
      # Would use :symbolize_names => true, but apparently there is
      # some library out there that makes symbolize_names not work.
      resp = Webpay::JSON.load(rbody)
    rescue MultiJson::DecodeError
      raise APIError.new("Invalid response object from API: #{rbody.inspect} (HTTP response code was #{rcode})", rcode, rbody)
    end

    resp = Util.symbolize_names(resp)
    [resp, api_key]
  end

  private

  def self.execute_request(opts)
    RestClient::Request.execute(opts)
  end

  def self.handle_api_error(rcode, rbody)
    begin
      error_obj = Webpay::JSON.load(rbody)
      error_obj = Util.symbolize_names(error_obj)
      error = error_obj[:error] or raise WebpayError.new # escape from parsing
    rescue MultiJson::DecodeError, WebpayError
      raise APIError.new("Invalid response object from API: #{rbody.inspect} (HTTP response code was #{rcode})", rcode, rbody)
    end

    case rcode
    when 400, 404 then
      raise invalid_request_error(error, rcode, rbody, error_obj)
    when 401
      raise authentication_error(error, rcode, rbody, error_obj)
    when 402
      raise card_error(error, rcode, rbody, error_obj)
    else
      raise api_error(error, rcode, rbody, error_obj)
    end
  end

  def self.invalid_request_error(error, rcode, rbody, error_obj)
    InvalidRequestError.new(error[:message], error[:param], rcode, rbody, error_obj)
  end

  def self.authentication_error(error, rcode, rbody, error_obj)
    AuthenticationError.new(error[:message], rcode, rbody, error_obj)
  end

  def self.card_error(error, rcode, rbody, error_obj)
    CardError.new(error[:message], error[:param], error[:code], rcode, rbody, error_obj)
  end

  def self.api_error(error, rcode, rbody, error_obj)
    APIError.new(error[:message], rcode, rbody, error_obj)
  end

  def self.handle_restclient_error(e)
    case e
    when RestClient::ServerBrokeConnection, RestClient::RequestTimeout
      message = "Could not connect to Webpay (#{@@api_base}).  Please check your internet connection and try again.  If this problem persists, you should check Webpay's service status at https://twitter.com/webpaystatus, or let us know at support@webpay.jp."
    when RestClient::SSLCertificateNotVerified
      message = "Could not verify Webpay's SSL certificate.  Please make sure that your network is not intercepting certificates.  (Try going to https://api.webpay.jp/v1 in your browser.)  If this problem persists, let us know at support@webpay.jp."
    when SocketError
      message = "Unexpected error communicating when trying to connect to Webpay.  HINT: You may be seeing this message because your DNS is not working.  To check, try running 'host webpay.jp' from the command line."
    else
      message = "Unexpected error communicating with Webpay.  If this problem persists, let us know at support@webpay.jp."
    end
    message += "\n\n(Network error: #{e.message})"
    raise APIConnectionError.new(message)
  end
end
