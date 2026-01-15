module OpenAI
  class Stream
    DONE = "[DONE]".freeze
    private_constant :DONE

    def initialize(user_proc:, parser: EventStreamParser::Parser.new)
      @user_proc = user_proc
      @parser = parser
      @accumulated_error = ""

      # To be backwards compatible, we need to check how many arguments the user_proc takes.
      @user_proc_arity =
        case user_proc
        when Proc
          user_proc.arity.abs
        else
          user_proc.method(:call).arity.abs
        end
    end

    def call(chunk, _bytes, env = nil)
      if env && env.status != 200
        @accumulated_error += chunk
        raise_error_when_ready(env)
      else
        parser.feed(chunk) do |event, data|
          next if data == DONE

          args = [JSON.parse(data), event].first(user_proc_arity)
          user_proc.call(*args)
        end
      end
    end

    def to_proc
      method(:call).to_proc
    end

    private

    attr_reader :user_proc, :parser, :user_proc_arity, :accumulated_error

    def raise_error_when_ready(env)
      parsed_error = try_parse_json(accumulated_error)
      return if parsed_error.is_a?(String)

      raise_error = Faraday::Response::RaiseError.new
      raise_error.on_complete(env.merge(body: parsed_error))
    end

    def try_parse_json(maybe_json)
      JSON.parse(maybe_json)
    rescue JSON::ParserError
      maybe_json
    end
  end
end
