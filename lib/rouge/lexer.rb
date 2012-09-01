module Rouge
  class Lexer
    class << self
      def make(opts={}, &b)
        _sup = self

        Class.new(self) do
          @lazy_load_proc = b
          @default_options = _sup.default_options.merge(opts)
          @parent = _sup
        end
      end

      def lex(stream, opts={})
        new(opts).lex(stream)
      end

    protected
      def force_load!
        return self if @force_load
        @force_load = true
        @lazy_load_proc && instance_eval(&@lazy_load_proc)

        self
      end
    public

      def new(*a, &b)
        force_load!
        super(*a, &b)
      end

      def default_options
        @default_options ||= {}
      end

      def find(name)
        registry[name.to_s]
      end

      def register(name, lexer)
        registry[name.to_s] = lexer
      end

      def tag(t=nil)
        return @tag if t.nil?

        @tag = t.to_s
        aliases @tag
      end

      def aliases(*args)
        args.each { |arg| Lexer.register(arg, self) }
      end

    private
      def registry
        @registry ||= {}
      end
    end

    # -*- instance methods -*- #

    def initialize(opts={}, &b)
      options(opts)
      @lazy_load_proc = b
    end

    def options(o={})
      (@options ||= {}).merge!(o)

      self.class.default_options.merge(@options)
    end

    def option(k, v=:absent)
      if v == :absent
        options[k]
      else
        options({ k => v })
      end
    end

    def debug(&b)
      puts(b.call) if option :debug
    end

    def get_tokens(stream)
      lex(stream).to_a
    end

    def lex(stream, &b)
      return enum_for(:lex, stream) unless block_given?

      stream_tokens(stream, &b)
    end

    def stream_tokens(stream, &b)
      raise 'abstract'
    end
  end

  class RegexLexer < Lexer
    class Rule
      attr_reader :callback
      attr_reader :next_state
      attr_reader :re
      def initialize(re, callback, next_state)
        @orig_re = re
        @re = Regexp.new %/\\A(?:#{re.source})/
        @callback = callback
        @next_state = next_state
      end

      def inspect
        "#<Rule #{@orig_re.inspect}>"
      end

      def consume(stream, &b)
        # TODO: I'm sure there is a much faster way of doing this.
        # also, encapsulate the stream in its own class.
        match = stream.match(@re)

        if match
          stream.slice!(0...$&.size)
          yield match
          return true
        end

        false
      end
    end

    class State
      attr_reader :name
      def initialize(name, &defn)
        @name = name
        @defn = defn
      end

      def rules
        @rules ||= []
      end

      def load!
        return self if @loaded
        @loaded = true
        StateDSL.new(rules).instance_eval(&@defn)
        self
      end
    end

    class StateDSL
      attr_reader :rules
      def initialize(rules)
        @rules = rules
      end

      def rule(re, token=nil, next_state=nil, &callback)
        if block_given?
          next_state = token
        else
          if token.is_a? String
            token = Token[token]
          end

          callback = proc { |match, &b| b.call token, match }
        end

        rules << Rule.new(re, callback, next_state)
      end

      def mixin(lexer_name)
        rules << lexer_name.to_s
      end
    end

    def self.states
      @states ||= {}
    end

    def self.state(name, &b)
      name = name.to_s
      states[name] = State.new(name, &b)
    end

    def initialize(parent=nil, opts={}, &defn)
      if parent.is_a? Hash
        opts = parent
        parent = nil
      end

      @parent = parent
      super(opts, &defn)
    end

    def states
      self.class.states
    end

    def get_state(name)
      state = states[name.to_s] 
      raise "unknown state: #{name}" unless state
      state.load!
    end

    def stream_tokens(stream, &b)
      stream = stream.dup
      stack = [get_state(:root)]

      stream_with_stack(stream.dup, stack, &b)
    end

    def stream_with_stack(stream, stack, &b)
      return true if stream.empty?

      until stream.empty?
        debug { "stack: #{stack.map(&:name).inspect}" }
        debug { "stream: #{stream.slice(0..20).inspect}" }
        success = step(stack.last, stream, stack, &b)

        if !success
          debug { "    no match, yielding Error" }
          b.call(Token['Error'], stream.slice!(0..0))
        end
      end
    end

    def step(state, stream, stack, &b)
      state.rules.each do |rule|
        return true if run_rule(rule, stream, stack, &b)
      end

      false
    end

  private
    def run_rule(rule, stream, stack, &b)
      case rule
      when String
        debug { "  entering mixin #{rule}" }
        step(get_state(rule), stream, stack, &b)
      when Rule
        debug { "  trying #{rule.inspect}" }
        rule.consume(stream) do |match|
          debug { "    got #{match[0].inspect}" }

          rule.callback.call(*match) do |tok, res|
            if tok.is_a? String
              tok = Token[tok]
            end

            debug { "    yielding #{tok.name.inspect}, #{res.inspect}" }
            b.call(tok, res)
          end

          if rule.next_state == :pop!
            debug { "    popping stack" }
            stack.pop
          elsif rule.next_state
            debug { "    entering #{rule.next_state}" }
            stack.push get_state(rule.next_state)
          end
        end
      end
    end

  end
end
