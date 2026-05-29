# frozen_string_literal: true

require "uri"
require "stringio"
require "rack/utils"

module Dommy
  module Rack
    # Builds a Rack-compatible env hash from a high-level request description.
    # Stateless aside from the session config it reads defaults from.
    class RequestBuilder
      FORM_URLENCODED = "application/x-www-form-urlencoded"
      BODY_METHODS = %w[POST PUT PATCH DELETE].freeze

      def initialize(config)
        @config = config
      end

      def build(method:, url:, headers: {}, body: nil, params: nil, cookie_string: "")
        raise ArgumentError, "pass either :params or :body, not both" if params && body

        verb = method.to_s.upcase
        uri = URI.parse(url)
        env_headers = normalize_headers(headers)

        body_string, query_extra, content_type = encode_payload(verb, params, body, env_headers)
        query = merge_query(uri.query, query_extra)

        env = base_env(verb, uri, query, body_string)
        apply_default_headers(env, env_headers, cookie_string)
        env["CONTENT_TYPE"] = content_type if content_type
        env.merge!(env_headers)
        env
      end

      private

      def base_env(verb, uri, query, body_string)
        {
          "REQUEST_METHOD" => verb,
          "SCRIPT_NAME" => "",
          "PATH_INFO" => uri.path.to_s.empty? ? "/" : uri.path,
          "QUERY_STRING" => query,
          "SERVER_NAME" => uri.host.to_s,
          "SERVER_PORT" => uri.port.to_s,
          "SERVER_PROTOCOL" => "HTTP/1.1",
          "HTTP_HOST" => host_header(uri),
          "CONTENT_LENGTH" => body_string.bytesize.to_s,
          "rack.url_scheme" => uri.scheme || "http",
          "rack.input" => StringIO.new(body_string),
          "rack.errors" => $stderr
        }
      end

      def apply_default_headers(env, env_headers, cookie_string)
        env["HTTP_ACCEPT"] = @config.accept unless env_headers.key?("HTTP_ACCEPT")
        env["HTTP_USER_AGENT"] = @config.user_agent unless env_headers.key?("HTTP_USER_AGENT")
        env["HTTP_COOKIE"] = cookie_string unless cookie_string.to_s.empty?
      end

      # Returns [body_string, query_extra, content_type]. For GET-style verbs,
      # params go into the query string and the body stays empty.
      def encode_payload(verb, params, body, env_headers)
        if params
          pairs = to_pairs(params)
          if BODY_METHODS.include?(verb)
            if FileUpload.multipart?(pairs)
              multipart_body, content_type = FileUpload.encode(pairs)
              [multipart_body, nil, content_type]
            else
              [encode_query(pairs), nil, env_headers["CONTENT_TYPE"] || FORM_URLENCODED]
            end
          else
            ["", encode_query(pairs), nil]
          end
        elsif body.is_a?(String)
          [body, nil, nil]
        elsif body.respond_to?(:read)
          [body.read.to_s, nil, nil]
        else
          ["", nil, nil]
        end
      end

      def merge_query(existing, extra)
        [existing, extra].compact.reject(&:empty?).join("&")
      end

      # Normalize params to ordered [name, value] pairs. A Hash expands array
      # values into repeated pairs; an Array is already ordered pairs. Keeping
      # order lets Rack reconstruct nested params (e.g. address[][street]).
      def to_pairs(params)
        if params.is_a?(::Hash)
          params.flat_map { |key, value| Array(value).map { |v| [key.to_s, v] } }
        else
          params.map { |key, value| [key.to_s, value] }
        end
      end

      # urlencode ordered pairs preserving order.
      def encode_query(pairs)
        pairs.map { |key, value| "#{::Rack::Utils.escape(key)}=#{::Rack::Utils.escape(scalar(value))}" }.join("&")
      end

      # File/Blob values can appear in a GET form; reduce them to their
      # filename so build_query never serializes raw bytes into a query.
      def scalar(value)
        return value.to_s unless value.respond_to?(:__dommy_bytes__)

        value.respond_to?(:name) ? value.name.to_s : ""
      end

      def normalize_headers(headers)
        headers.each_with_object({}) do |(name, value), acc|
          acc[normalize_header_name(name)] = value.to_s
        end
      end

      def normalize_header_name(name)
        key = name.to_s
        case key.downcase
        when "content-type" then "CONTENT_TYPE"
        when "content-length" then "CONTENT_LENGTH"
        else "HTTP_#{key.upcase.tr("-", "_")}"
        end
      end

      def host_header(uri)
        default = uri.scheme == "https" ? 443 : 80
        uri.port && uri.port != default ? "#{uri.host}:#{uri.port}" : uri.host.to_s
      end
    end
  end
end
