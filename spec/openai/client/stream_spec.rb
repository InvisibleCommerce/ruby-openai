RSpec.describe OpenAI::Stream do
  let(:user_proc) { proc { |data, event| [data, event] } }
  let(:stream) { OpenAI::Stream.new(user_proc: user_proc) }
  let(:bytes) { 0 }
  let(:env) { Faraday::Env.new.tap { |env| env.status = 200 } }

  describe "#call" do
    context "with a proc" do
      context "when called with a string containing a single JSON object" do
        it "calls the user proc with the data parsed as JSON" do
          expect(user_proc).to receive(:call)
            .with(
              JSON.parse('{"foo": "bar"}'),
              "event.test"
            )

          stream.call(<<~CHUNK, bytes, env)
            event: event.test
            data: { "foo": "bar" }

            #
          CHUNK
        end
      end

      context "when called with a string containing more than one JSON object" do
        it "calls the user proc for each data parsed as JSON" do
          expect(user_proc).to receive(:call)
            .with(
              JSON.parse('{"foo": "bar"}'),
              "event.test.first"
            )
          expect(user_proc).to receive(:call)
            .with(
              JSON.parse('{"baz": "qud"}'),
              "event.test.second"
            )

          stream.call(<<~CHUNK, bytes, env)
            event: event.test.first
            data: { "foo": "bar" }

            event: event.test.second
            data: { "baz": "qud" }

            event: event.complete
            data: [DONE]

            #
          CHUNK
        end
      end

      context "when called with string containing invalid JSON" do
        let(:chunk) do
          <<~CHUNK
            event: event.test
            data: { "foo": "bar" }

            data: NOT JSON

            #
          CHUNK
        end

        it "raise an error" do
          expect(user_proc).to receive(:call)
            .with(
              JSON.parse('{"foo": "bar"}'),
              "event.test"
            )

          expect do
            stream.call(chunk, bytes, env)
          end.to raise_error(JSON::ParserError)
        end
      end

      context "when called with JSON split across chunks" do
        it "calls the user proc with the data parsed as JSON" do
          expect(user_proc).to receive(:call)
            .with(
              JSON.parse('{ "foo": "bar" }'),
              "event.test"
            )

          expect do
            stream.call("event: event.test\n", bytes, env)
            stream.call("data: { \"foo\":", bytes, env)
            stream.call(" \"bar\" }\n\n", bytes, env)
          end.not_to raise_error
        end
      end

      context "with a HTTP error response with body containing JSON split across chunks" do
        let(:error_env) do
          Faraday::Env.from(
            method: :post,
            url: URI("http://example.com"),
            status: 400,
            request: {},
            response: Faraday::Response.new
          )
        end
        let(:expected_body) do
          {
            "error" => {
              "message" => "Test error",
              "type" => "test_error",
              "param" => nil,
              "code" => "test"
            }
          }
        end

        it "raises an error" do
          json = expected_body.to_json
          # Split the JSON into two chunks in the middle
          chunks = [json[0..(json.length / 2)], json[((json.length / 2) + 1)..]]

          expect do
            chunks.each do |chunk|
              stream.call(chunk, bytes, error_env)
            end
          end.to raise_error(Faraday::BadRequestError) do |e|
            expect(e.response).to include(status: 400)
            expect(e.response[:body]).to eq(expected_body)
          end
        end

        it "does not call user proc on error" do
          expect(user_proc).not_to receive(:call)

          json = expected_body.to_json
          chunks = [json[0..(json.length / 2)], json[((json.length / 2) + 1)..]]

          expect do
            chunks.each do |chunk|
              stream.call(chunk, bytes, error_env)
            end
          end.to raise_error(Faraday::BadRequestError)
        end
      end

      context "with a call method that only takes one argument" do
        let(:user_proc) { proc { |data| data } }

        it "succeeds" do
          expect(user_proc).to receive(:call).with(JSON.parse('{"foo": "bar"}'))

          stream.call(<<~CHUNK, bytes, env)
            event: event.test
            data: { "foo": "bar" }

            #
          CHUNK
        end
      end

      context "when called with only 2 arguments (like Faraday 2.1.0)" do
        it "handles the call without env parameter" do
          expect(user_proc).to receive(:call)
            .with(
              JSON.parse('{"foo": "bar"}'),
              "event.test"
            )

          # Faraday 2.1.0 calls with only (chunk, size), not (chunk, size, env)
          expect do
            stream.call(<<~CHUNK, bytes)
              event: event.test
              data: { "foo": "bar" }

              #
            CHUNK
          end.not_to raise_error
        end
      end
    end
  end

  describe "#to_proc" do
    it "returns a proc" do
      expect(stream.to_proc).to be_a(Proc)
    end
  end
end
