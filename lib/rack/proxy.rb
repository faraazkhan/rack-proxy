require "net_http_hacked"
require "rack/http_streaming_response"

module Rack

  # Subclass and bring your own #rewrite_request and #rewrite_response
  class Proxy
    VERSION = "0.5.8"

    # @option opts [String, URI::HTTP] :backend Backend host to proxy requests to
    def initialize(opts={})
      @streaming = opts.fetch(:streaming, true)
      @ssl_verify_none = opts.fetch(:ssl_verify_none, false)
      @backend = URI(opts[:backend]) if opts[:backend]
    end

    def call(env)
      rewrite_response(perform_request(rewrite_env(env)))
    end

    # Return modified env
    def rewrite_env(env)
      env
    end

    # Return a rack triplet [status, headers, body]
    def rewrite_response(triplet)
      triplet
    end

    protected

    def perform_request(env)
      source_request = Rack::Request.new(env)

      # Initialize request
      if source_request.fullpath == ""
        full_path = URI.parse(env['REQUEST_URI']).request_uri
      else
        full_path = source_request.fullpath
      end

      target_request = Net::HTTP.const_get(source_request.request_method.capitalize).new(full_path)

      # Setup headers
      target_request.initialize_http_header(extract_http_request_headers(source_request.env))

      # Setup body
      if target_request.request_body_permitted? && source_request.body
        target_request.body_stream    = source_request.body
        target_request.content_length = source_request.content_length.to_i
        target_request.content_type   = source_request.content_type if source_request.content_type
        target_request.body_stream.rewind
      end

      # Create a streaming response (the actual network communication is deferred, a.k.a. streamed)
      target_response = HttpStreamingResponse.new(target_request, source_request.host, source_request.port)

      backend = @backend || source_request
      use_ssl = backend.scheme == "https"
      ssl_verify_none = (env.delete('rack.ssl_verify_none') || @ssl_verify_none) == true

      # Create the response
      if @streaming
        # streaming response (the actual network communication is deferred, a.k.a. streamed)
        target_response = HttpStreamingResponse.new(target_request, backend.host, backend.port)
        target_response.use_ssl = use_ssl
        target_response.verify_mode = OpenSSL::SSL::VERIFY_NONE if use_ssl && ssl_verify_none
      else
        http = Net::HTTP.new(backend.host, backend.port)
        http.use_ssl = use_ssl
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE if use_ssl && ssl_verify_none
        target_response = http.request(target_request)
      end

      headers = (target_response.respond_to?(:headers) && target_response.headers) || {}
      body    = target_response.body
      body    = [body] unless body.respond_to?(:each)

      [target_response.code, headers, body]
    end

    def extract_http_request_headers(env)
      headers = env.reject do |k, v|
        !(/^HTTP_[A-Z_]+$/ === k) || v.nil?
      end.map do |k, v|
        [reconstruct_header_name(k), v]
      end.inject(Utils::HeaderHash.new) do |hash, k_v|
        k, v = k_v
        hash[k] = v
        hash
      end

      x_forwarded_for = (headers["X-Forwarded-For"].to_s.split(/, +/) << env["REMOTE_ADDR"]).join(", ")

      headers.merge!("X-Forwarded-For" =>  x_forwarded_for)
    end

    def reconstruct_header_name(name)
      name.sub(/^HTTP_/, "").gsub("_", "-")
    end

  end

end
