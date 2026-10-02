module Citrine
  class Error < Exception
    getter filename : String?
    getter line_number : Int32?
    getter column_number : Int32?

    def initialize(
      message : String,
      @filename : String? = nil,
      @line_number : Int32? = nil,
      @column_number : Int32? = nil
    )
      loc = ""
      if fn = @filename
        loc = "#{fn}:"
        loc += "#{@line_number}:" if @line_number
        loc += "#{@column_number}:" if @column_number
        loc += " "
      end
      super("#{loc}#{message}")
    end
  end

  class ParseError < Error
  end

  class CompileError < Error
  end
end
