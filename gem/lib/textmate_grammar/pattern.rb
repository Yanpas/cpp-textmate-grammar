# frozen_string_literal: true

require 'deep_clone'
require 'yaml'
require 'textmate_grammar/grammar_plugin.rb'

# Add remove indent to the String class
class String
    # a helper for writing multi-line strings for error messages
    # example usage
    #     puts <<-HEREDOC.remove_indent
    #     This command does such and such.
    #         this part is extra indented
    #     HEREDOC
    def remove_indent
        gsub(/^[ \t]{#{match(/^[ \t]*/)[0].length}}/, '')
    end
end

# determines if a regex string is a single entity
#
# @note single entity means that for the purposes of modification, the expression is
#   atomic, for example if appending a `+` to the end of `regex_string` matches only
#   a prt of regex string multiple times then it is not atomic
# @param regex_string [String] a string representing a regular expression, without the
#   forward slash "/" at the begining and
# @return [Boolean] if the string represents an single regex entity
def string_single_entity?(regex_string)
    return true if regex_string.length == 2 && regex_string[0] == '\\'

    escaped = false
    in_set = false
    depth = 0
    regex_string.each_char.with_index do |c, index|
        # allow the first character to be at depth 0
        # NOTE: this automatically makes a single char regexp a single entity
        return false if depth == 0 && index != 0

        if escaped
            escaped = false
            next
        end
        if c == '\\'
            escaped = true
            next
        end
        if in_set
            if c == ']'
                in_set = false
                depth -= 1
            end
            next
        end
        case c
        when "(" then depth += 1
        when ")" then depth -= 1
        when "["
            depth += 1
            in_set = true
        end
    end
    # sanity check
    if depth != 0 or escaped or in_set
        puts "Internal error: when determining if a Regexp is a single entity"
        puts "an unexpected sequence was found. This is a bug with the gem."
        puts "This will not effect the validity of the produced grammar"
        puts "Regexp: #{inspect} depth: #{depth} escaped: #{escaped} in_set: #{in_set}"
        return false
    end
    true
end

# Add convience methds to make Regexp behave a bit more like Pattern
class Regexp

    # (see #string_single_entity?)
    # @deprecated use string_single_entity
    def single_entity?
        string_single_entity? to_r_s
    end

    # (see Pattern#to_r)
    # @deprecated function is useless
    def to_r(*)
        self
    end

    # display the regex as a clean string
    def to_r_s
        inspect[1..-2]
    end
end

class Pattern
    # @return [Pattern] The next pattern in the linked list of patterns
    # @api private
    attr_accessor :next_pattern
    # @return [Hash] The original arguments passed into initialize
    attr_accessor :original_arguments

    #
    # Helpers
    #

    #

    #
    # does @arguments contain any attributes that require this pattern be captured?
    #
    # @return [Boolean] if this Pattern needs to capture
    #
    def needs_to_capture?
        capturing_attributes = [
            :tag_as,
            :reference,
            :includes,
        ]
        puts @match.class unless @arguments.is_a? Hash

        !(@arguments.keys & capturing_attributes).empty?
    end

    #
    # Can the capture be optimized out
    #
    # When the pattern has nothing after it then its capture can instead become
    # capture group 0
    #
    # @return [Boolean] can this capture become capture group 0
    #
    def optimize_outer_group?
        needs_to_capture? and @next_pattern.nil?
    end


    #
    # Appends pattern to the linked list of patterns
    #
    # @param [Pattern] pattern the pattern to append
    #
    # @return [self]
    #
    # @see insert
    #
    def insert!(pattern)
        last = self
        last = last.next_pattern while last.next_pattern
        last.next_pattern = pattern
        self
    end

    #
    # Append pattern to a copy of the linked list of patterns
    #
    # @param [Pattern] pattern the pattern to append
    #
    # @return [Pattern] a copy of self with pattern appended
    #
    def insert(pattern)
        new_pattern = __deep_clone__
        new_pattern.insert!(pattern)
    end

    #
    # sets @at_least and @at_most based on arguments
    #
    # @return [void]
    #
    # @api private
    #
    def process_quantifiers_from_arguments
        # this sets the @at_most and @at_least value based on the arguments

        #
        # Simplify the quantity down to just :at_least and :at_most
        #
        attributes_clone = @arguments.clone
        # convert Enumerators to numbers
        [:at_least, :at_most, :how_many_times?].each do |each|
            if attributes_clone[each].is_a?(Enumerator)
                attributes_clone[each] = attributes_clone[each].size
            end
        end
        # extract the data
        at_least       = attributes_clone[:at_least]
        at_most        = attributes_clone[:at_most]
        how_many_times = attributes_clone[:how_many_times?]
        # simplify to at_least and at_most
        at_least = at_most = how_many_times if how_many_times.is_a?(Integer)

        # check if quantifying is allowed
        # check after everything else encase additional quantifing options are created in the future
        if quantifing_allowed?
            @at_least = at_least
            @at_most = at_most
        # if a quantifying value was set and quantifying is not allowed, raise an error
        # telling the user that its not allowed
        elsif !(at_most.nil? && at_least.nil?)
            raise <<-HEREDOC.remove_indent

                Inside of the #{name} pattern, there are some quantity arguments like:
                    :at_least
                    :at_most
                    or :how_many_times?
                These are not allowed in this kind of #{do_get_to_s_name}) pattern
                If you did this intentionally please wrap it inside of a Pattern.new()
                ex: #{do_get_to_s_name} Pattern.new( *your_arguments* ) )
            HEREDOC
        end
    end


    #
    # converts @at_least and @at_most into the appropriate quantifier
    # this is a simple_quantifier because it does not include atomic-ness
    #
    # @return [String] the quantifier
    #
    def simple_quantifier
        # Generate the ending based on :at_least and :at_most

        # by default assume no quantifiers
        quantifier = ""
        # if there is no at_least, at_most, or how_many_times, then theres no quantifier
        if @at_least.nil? and @at_most.nil?
            quantifier = ""
        # if there is a quantifier
        else
            # if there's no at_least, then assume at_least = 1
            @at_least = 1 if @at_least.nil?

            quantifier =
                if @at_least == 0 and @at_most == 1
                    # this is just a different way of "maybe"
                    "?"
                elsif @at_least == 0 and @at_most.nil?
                    # this is just a different way of "zeroOrMoreOf"
                    "*"
                elsif @at_least == 1 and @at_most.nil?
                    # this is just a different way of "oneOrMoreOf"
                    "+"
                elsif @at_least == @most
                    # exactly N times
                    "{#{@at_least}}"
                else
                    # if it is more complicated than that, just use a range
                    "{#{@at_least},#{@at_most}}"
                end
        end
        # quantifiers can be made possesive without requiring atomic groups
        quantifier += "+" if quantifier != "" && @arguments[:dont_back_track?] == true
        quantifier
    end

    # this method handles adding the at_most/at_least, dont_back_track methods
    # it returns regex-as-a-string

    #
    # Adds quantifiers to match
    #
    # @param [String, Pattern] match the pattern to add a quantifier to
    # @param [Array] groups group information, used for evaluating match
    #
    # @return [String] match with quantifiers applied
    #
    def add_quantifier_options_to(match, groups)
        match = match.evaluate(groups) if match.is_a? Pattern
        quantifier = simple_quantifier
        # check if there are quantifiers
        if quantifier != ""
            # if the match is not a single entity, then it needs to be wrapped
            match = "(?:#{match})" unless string_single_entity?(match)
            # add the quantified ending
            match += quantifier
        elsif @arguments[:dont_back_track?] == true
            # make atomic, which allows arbitary expression to be prevented from backtracking
            match = "(?>#{match})"
        end
        if @arguments[:word_cannot_be_any_of]
            word_pattern = @arguments[:word_cannot_be_any_of].map {|w| Regexp.escape w}.join "|"
            match = "(?!\\b(?:#{word_pattern})\\b)#{match}"
        end
        match
    end

    #
    # Adds a capture group if needed
    #
    # @param [String] regex_as_string the pattern as a string
    #
    # @return [String] the pattern, potentially with a cpature group
    #
    def add_capture_group_if_needed(regex_as_string)
        regex_as_string = "(#{regex_as_string})" if needs_to_capture?
        regex_as_string
    end

    #
    # Uses block to recursively transform includes
    #
    # @param [Block] &block the block to transform includes
    #
    # @return [self]
    #
    def transform_includes!(&block)
        if @arguments[:includes]
            if @arguments[:includes].is_a? Array
                @arguments[:includes].map!(&block)
            else
                @arguments[:includes] = block.call @arguments[:includes]
            end
        end

        @match.transform_includes!(block) if @match.is_a? Pattern
        @next_pattern.transform_includes!(block) if @next_pattern.is_a? Pattern

        self
    end

    #
    # (see transform_includes!)
    # @return [Pattern] a copy of self with transformed includes
    #
    def transform_includes(&block)
        __deep_clone__.transform_includes!(&block)
    end

    #
    # Uses block to recursively transform tag_as
    #
    # @param [Block] &block the block to transform tag_as
    #
    # @return [self]
    #
    def transform_tag_as!(&block)
        if @arguments[:tag_as]
            @arguments[:tag_as] = block.call @arguments[:tag_as]
        end

        @match.transform_tag_as!(block) if @match.is_a? Pattern
        @next_pattern.transform_tag_as!(block) if @next_pattern.is_a? Pattern

        self
    end

    #
    # (see transform_tag_as!)
    # @return [Pattern] a copy of self with transformed tag_as
    #
    def transform_tag_as(&block)
        __deep_clone__.transform_tag_as!(&block)
    end

    #
    # Public interface
    #

    #
    # Construct a new pattern
    #
    # @overload initialize(pattern)
    #   matches an exact pattern
    #   @param pattern [Pattern, Regexp, String] the pattern to match
    # @overload initialize(opts)
    #   @param opts [Hash] options
    #   @option opts [Pattern, Regexp, String] :match the pattern to match
    #   @option opts [String] :tag_as what to tag this pattern as
    #   @option opts [Array<Pattern, Symbol>] :includes pattern includes
    #   @option opts [String] :reference a name for this pattern can be refered to in
    #       earlier or later parts of the pattern list, or in tag_as
    #   @option opts [Array<String>] :should_fully_match string that this pattern should
    #       fully match
    #   @option opts [Array<String>] :should_partial_match string that this pattern should
    #       partially match
    #   @option opts [Array<String>] :should_not_fully_match string that this pattern should
    #       not fully match
    #   @option opts [Array<String>] :should_not_partial_match string that this pattern should
    #       not partially match
    #   @option opts [Enumerator, Integer] :at_most match up to N times, nil to match any
    #       number of times
    #   @option opts [Enumerator, Integer] :at_least match no fewer tahn N times, nil to
    #       match any number of times
    #   @option opts [Enumerator, Integer] :how_many_times match exactly N times
    #   @option opts [Array<String>] :word_cannot_be_any_of list of wordlike string that
    #       the pattern should not match (this is a qualifier not a unit test)
    #   @option opts [Boolean] :dont_back_track? can this pattern backtrack
    #   @note Plugins may provide additional options
    #   @note all options except :match are optional
    # @overload initialize(opts, deep_clone, original)
    #   makes a copy of Pattern
    #   @param opts [Hash] the original patterns @arguments with match
    #   @param deep_clone [:deep_clone] identifies as a deep_clone construction
    #   @param original [Hash] the original patterns @original_arguments
    #   @api private
    #   @note this should only be called by __deep_clone__, however subclasses must be
    #       able to accept this form
    #
    def initialize(*arguments)
        if arguments.length > 1 && arguments[1] == :deep_clone
            @arguments = arguments[0]
            @match = @arguments[:match]
            @arguments.delete(:match)
            @original_arguments = arguments[2]
            return
        end

        if arguments.length > 1
            # Pattern was likely constucted like `Pattern.new(/foo/, option: bar)`
            puts "Pattern#new() expects a single Regexp, String, or Hash"
            puts "Pattern#new() was provided with multiple arguments"
            puts "arguments:"
            puts arguments
            raise "See error above"
        end
        @next_pattern = nil
        arg1 = arguments[0]
        arg1 = {match: arg1} unless arg1.is_a? Hash
        @original_arguments = arg1.clone
        if arg1[:match].is_a? String
            arg1[:match] = Regexp.escape(arg1[:match])
            @match = arg1[:match]
        elsif arg1[:match].is_a? Regexp
            raise_if_regex_has_capture_group arg1[:match]
            @match = arg1[:match].to_r_s
        elsif arg1[:match].is_a? Pattern
            @match = arg1[:match]
        else
            puts <<-HEREDOC.remove_indent
                Pattern.new() must be constructed with a String, Regexp, or Pattern
                Provided arguments: #{@original_arguments}
            HEREDOC
            raise "See error above"
        end
        arg1.delete(:match)
        @arguments = arg1

        @at_most = nil
        @at_least = nil
    end

    # attempts to provide a memorable name for a pattern
    def name
        return @arguments[:reference] unless @arguments[:reference].nil?

        return @arguments[:tag_as] unless @arguments[:tag_as].nil?

        to_s
    end

    # converts a Pattern to a Hash represnting a textmate pattern
    def to_tag
        regex_as_string = evaluate
        output = {
            match: regex_as_string,
        }
        if optimize_outer_group?
            # optimize captures by removing outermost
            output[:match] = output[:match][1..-2]
            output[:name] = @arguments[:tag_as]
        end

        output[:captures] = convert_group_attributes_to_captures(collect_group_attributes)
        output.reject! { |_, v| !v || v.empty? }
        output
    end

    # evaluates the pattern into a string suitable for inserting into a
    # grammar or constructing a Regexp.
    # if groups is nil consider this Pattern to be the top_level
    # when a pattern is top_level, group numbers and back references are relative to that pattern
    def evaluate(groups = nil)
        top_level = groups.nil?
        groups = collect_group_attributes if top_level
        self_evaluate = do_evaluate_self(groups)
        if @next_pattern.respond_to?(:integrate_pattern)
            single_entity = string_single_entity?(self_evaluate)
            self_evaluate = @next_pattern.integrate_pattern(self_evaluate, groups, single_entity)
        end
        self_evaluate = fixup_regex_references(groups, self_evaluate) if top_level
        self_evaluate
    end

    # converts a pattern to a Regexp
    # if groups is nil consider this Pattern to be the top_level
    # when a pattern is top_level, group numbers and back references are relative to that pattern
    def to_r(*args)
        Regexp.new(evaluate(*args))
    end

    # Displays the Pattern as you would write it in code
    # TODO: make this function easier to understand
    def to_s(depth = 0, top_level = true)
        # rubocop:disable Metrics/LineLength

        plugins = Grammar.plugins
        plugins.reject! { |p| (@original_arguments.keys & p).empty? }

        regex_as_string = case @original_arguments[:match]
            when Pattern then @original_arguments[:match].to_s(depth + 2, true)
            when Regexp then @original_arguments[:match].inspect
            when String then "/" + Regexp.escape(@original_arguments[:match]) + "/"
        end
        regex_as_string = do_modify_regex_string(regex_as_string)
        indent = "  " * depth
        output = indent + do_get_to_s_name(top_level)
        # basic pattern information
        output += "\n#{indent}  match: " + regex_as_string.lstrip
        output += ",\n#{indent}  tag_as: \"" + @arguments[:tag_as] + '"' if @arguments[:tag_as]
        output += ",\n#{indent}  reference: \"" + @arguments[:reference] + '"' if @arguments[:reference]
        # unit tests
        output += ",\n#{indent}  should_fully_match: " + @arguments[:should_fully_match] if @arguments[:should_fully_match]
        output += ",\n#{indent}  should_not_fully_match: " + @arguments[:should_not_fully_match] if @arguments[:should_not_fully_match]
        output += ",\n#{indent}  should_partially_match: " + @arguments[:should_partially_match] if @arguments[:should_partially_match]
        output += ",\n#{indent}  should_not_partially_match: " + @arguments[:should_not_partially_match] if @arguments[:should_not_partially_match]
        # special #then arguments
        if quantifing_allowed?
            output += ",\n#{indent}  at_least: \"" + @arguments[:at_least] + '"' if @arguments[:at_least]
            output += ",\n#{indent}  at_most: \"" + @arguments[:at_most] + '"' if @arguments[:at_most]
            output += ",\n#{indent}  how_many_times: \"" + @arguments[:how_many_times] + '"' if @arguments[:how_many_times]
            output += ",\n#{indent}  word_cannot_be_any_of: " + @arguments[:word_cannot_be_any_of] if @arguments[:word_cannot_be_any_of]
        end
        output += ",\n#{indent}  dont_backtrack?: \"" + @arguments[:dont_backtrack?] + '"' if @arguments[:dont_backtrack?]
        # add any linter/transform configurations
        plugins.each { |p| output += p.display_options(indent + "  ", @original_arguments) }
        # subclass, ending and recursive
        output += do_add_attributes(indent)
        output += ",\n#{indent})"
        output += @next_pattern.to_s(depth, false).lstrip if @next_pattern
        output
        # rubocop:enable Metrics/LineLength
    end

    def run_tests
        pass = [true]

        self_regex = @match.to_r
        warn = lambda do |symbol|
            puts <<-HEREDOC.remove_indent

                When testing the pattern #{self_regex.evaluate}. The unit test for #{symbol} failed.
                The unit test has the following patterns:
                #{@arguments[symbol].to_yaml}
                The Failing pattern is below:
                #{self}
            HEREDOC
        end
        if @arguments[:should_fully_match].is_a? Array
            test_regex = /^(?:#{self_regex})$/
            if @arguments[:should_fully_match].all? { |test| test =~ test_regex } == false
                warn.call :should_fully_match
                pass << false
            end
        end
        if @arguments[:should_not_fully_match].is_a? Array
            test_regex = /^(?:#{self_regex})$/
            if @arguments[:should_not_fully_match].none? { |test| test =~ test_regex } == false
                warn.call :should_not_fully_match
                pass << false
            end
        end
        if @arguments[:should_partially_match].is_a? Array
            test_regex = self_regex
            if @arguments[:should_partially_match].all? { |test| test =~ test_regex } == false
                warn.call :should_partially_match
                pass << false
            end
        end
        if @arguments[:should_not_partially_match].is_a? Array # rubocop: disable Style/GuardClause
            test_regex = self_regex
            if @arguments[:should_not_partially_match].none? { |test| test =~ test_regex } == false
                warn.call :should_not_partially_match
                pass << false
            end
        end
        # run related unit tests
        pass << @match.run_tests if @match.is_a? Pattern
        pass << @next_pattern.run_tests if @next_pattern.is_a? Pattern
        @arguments[:includes]&.each { |inc| pass << inc.run_tests if inc.is_a? Pattern }
        pass.none? { |v| !v}
    end

    def start_pattern
        self
    end

    def hash
        @match.hash
    end

    def eql?(other)
        return false unless other.is_a? Pattern
        to_tag == other.to_tag
    end

    def ==(other)
        eql? other
    end

    #
    # Chaining
    #
    def then(pattern)
        pattern = Pattern.new(pattern) unless pattern.is_a? Pattern
        insert(pattern)
    end
    # other methods added by subclasses

    #
    # Inheritance
    #

    # this method should return false for child classes
    # that manually set the quantity themselves: e.g. MaybePattern, OneOrMoreOfPattern, etc
    def quantifing_allowed?
        true
    end

    # convert convert @match and any applicable arguments into a complete regex for self
    # despite the name, this returns on strings
    # called by #to_r
    def do_evaluate_self(groups)
        add_capture_group_if_needed(add_quantifier_options_to(@match, groups))
    end

    # this pattern handles combining the previous pattern with the next pattern
    # in most situtaions, this just means concatenation
    def integrate_pattern(previous_evaluate, groups, _is_single_entity)
        # by default just concat the groups
        "#{previous_evaluate}#{evaluate(groups)}"
    end

    # what modifications to make to @match.to_s
    # called by #to_s
    def do_modify_regex_string(self_regex)
        self_regex
    end

    # return a string of any additional attributes that need to be added to the #to_s output
    # indent is a string with the amount of space the parent block is indented, attributes
    # are indented 2 more spaces
    # called by #to_s
    def do_add_attributes(_indent)
        ""
    end

    # What is the name of the method that the user would call
    # top_level is if a freestanding or chaining function is called
    # called by #to_s
    def do_get_to_s_name(top_level)
        top_level ? "Pattern.new(" : ".then("
    end

    # is the result of #to_r atomic for the purpose of regex building.
    # /(?:a|b)/ is atomic /(a)(b|c)/ is not. the safe answer is false.
    # NOTE: this is not the same concept as atomic groups, all groups are considered
    #   atomic for the purpose of regex building
    # called by #to_r
    def single_entity?
        to_r.single_entity?
    end

    # does this pattern contain no capturing groups
    def groupless?
        collect_group_attributes == []
    end

    # remove capturing groups from this pattern
    def groupless!
        @arguments.delete(:tag_as)
        @arguments.delete(:reference)
        @arguments.delete(:includes)
        raise "unable to remove capture" if needs_to_capture?

        @match.groupless! if @match.is_a? Pattern
        @next_pattern.groupless! if @match.is_a? Pattern
        self
    end

    # create a copy of this pattern that contains no groups
    def groupless
        __deep_clone__.groupless!
    end

    def reTag!(arguments)
        # tags are keep unless `all: false` or `keep: false`, and append is not a string
        discard_tag = (arguments[:all] == false || arguments[:keep] == false)
        discard_tag = false if arguments[:append].is_a? String

        arguments.each do |key, tag|
            if [@arguments[:tag_as], @arguments[:reference]].include? key
                @arguments[:tag_as] = tag
                discard_tag = false
            end
        end

        if arguments[:append].is_a?(String) && arguments[:tag_as]
            arguments[:tag_as] = arguments[:tag_as] + "." + arguments[:append]
        end

        @arguments.delete(:tag_as) if discard_tag

        @next_pattern&.reTag!(arguments)
        self
    end

    def reTag(arguments)
        __deep_clone__.reTag!(arguments)
    end

    #
    # Internal
    #
    def collect_group_attributes(next_group = optimize_outer_group? ? 0 : 1)
        groups = []
        if needs_to_capture?
            groups << {group: next_group}.merge(@arguments)
            next_group += 1
        end
        if @match.is_a? Pattern
            new_groups = @match.collect_group_attributes(next_group)
            groups.concat(new_groups)
            next_group += new_groups.length
        end
        if @next_pattern.is_a? Pattern
            new_groups = @next_pattern.collect_group_attributes(next_group)
            groups.concat(new_groups)
        end
        groups
    end

    def fixup_regex_references(groups, self_regex)
        # rubocop:disable Metrics/LineLength
        references = {}
        # convert all references to group numbers
        groups.each do |group|
            references[group[:reference]] = group[:group] unless group[:reference].nil?
        end

        # convert back references
        self_regex = self_regex.gsub(/\[:backreference:([^\\]+?):\]/) do
            match_reference = Regexp.last_match(1)
            if references[match_reference].nil?
                raise "\nWhen processing the matchResultOf:#{match_reference}, I couldn't find the group it was referencing"
            end

            # if the reference does exist, then replace it with it's number
            "\\#{references[match_reference]}"
        end

        # check for a subroutine to the Nth group, replace it with `\N`
        self_regex = self_regex.gsub(/\[:subroutine:([^\\]+?):\]/) do
            match_reference = Regexp.last_match(1)
            if references[match_reference].nil?
                raise "\nWhen processing the recursivelyMatch:#{match_reference}, I couldn't find the group it was referencing"
            end

            # if the reference does exist, then replace it with it's number
            "\\g<#{references[match_reference]}>"
        end
        # rubocop:enable Metrics/LineLength
        self_regex
    end

    def convert_group_attributes_to_captures(groups)
        captures = {}

        groups.each do |group|
            output = {}
            output[:name] = group[:tag_as] unless group[:group] == 0
            if !group[:includes].nil?
                output[:patterns] = convert_includes_to_patterns(group[:includes])
            end
            captures[group[:group].to_s] = output
        end
        captures.reject! { |_, v| v.empty? }
        # replace $match and $reference() with the appropriate capture number
        captures.each do |key, value|
            next if value[:name].nil?

            value[:name] = value[:name].gsub(/\$(?:match|reference\((.+)\))/) do |match|
                next ("$" + key) if match == "$match"

                reference_group = groups.detect do |group|
                    group[:reference] == Regexp.last_match(1)
                end
                "$" + reference_group[:group].to_s
            end
        end
    end

    def convert_includes_to_patterns(includes)
        includes = [includes] unless includes.is_a? Array
        patterns = includes.flatten.map do |rule|
            next {include: "##{rule}"} if rule.is_a? Symbol

            rule = Pattern.new(rule) unless rule.is_a? Pattern
            rule.to_tag
        end
        patterns
    end

    def __deep_clone__
        options = @arguments.__deep_clone__
        options[:match] = @match.__deep_clone__
        new_pattern = self.class.new(options, :deep_clone, @original_arguments)
        new_pattern.insert! @next_pattern.__deep_clone__
    end

    def raise_if_regex_has_capture_group(regex)
        # this will throw a RegexpError if there are no capturing groups
        _ignore = /#{regex}\1/
        # at this point @match contains a capture group, complain
        raise <<-HEREDOC.remove_indent

            There is a pattern that is being constructed from a regular expression
            with a capturing group. This is not allowed, as the group cannot be tracked
            The bad pattern is
            #{self}
        HEREDOC
    rescue RegexpError # rubocop: disable Lint/HandleExceptions
        # no cpature groups present, purposely do nothing
    end
end