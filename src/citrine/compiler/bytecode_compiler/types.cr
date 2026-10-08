module Citrine
  class CompiledFunction
    property name : String
    property argc : UInt8
    property num_registers : UInt8
    property code_offset : UInt32 = 0_u32
    property instruction_count : UInt32 = 0_u32
    property instructions : Array(Instruction)

    def initialize(@name : String, @argc : UInt8 = 0_u8)
      @num_registers = @argc
      @instructions = [] of Instruction
    end
  end

  enum ConstType : UInt8
    Nil     = 0
    Bool    = 1
    Int32   = 2
    Float32 = 3
    Vec2    = 4
    Color   = 5
    String  = 6
  end

  struct ConstValue
    getter type : ConstType
    getter int_val : Int32
    getter uint_val : UInt32
    getter float_val : Float32
    getter float_val2 : Float32
    getter str_val : String

    def initialize(
      @type : ConstType,
      @int_val : Int32 = 0,
      @uint_val : UInt32 = 0_u32,
      @float_val : Float32 = 0.0_f32,
      @float_val2 : Float32 = 0.0_f32,
      @str_val : String = ""
    )
    end
  end

  class ModuleInfo
    getter module_id : UInt32
    getter name : String
    getter methods : Hash(String, Crystal::Def)
    getter included_module_ids : Array(UInt32) = [] of UInt32

    def initialize(@module_id : UInt32, @name : String)
      @methods = Hash(String, Crystal::Def).new
    end
  end

  class ClassInfo
    getter class_id : UInt32
    getter name : String
    property superclass_name : String? = nil
    property superclass_id : UInt32? = nil
    property included_module_ids : Array(UInt32) = [] of UInt32
    property is_abstract : Bool = false
    property is_struct : Bool = false
    property abstract_methods : Set(String) = Set(String).new
    getter fields : Hash(String, Int32)
    getter field_types : Hash(String, String)
    getter methods : Hash(String, Crystal::Def)
    getter method_return_types : Hash(String, String)
    getter class_fields : Hash(String, Int32)
    getter class_methods : Hash(String, Crystal::Def)

    def initialize(@class_id : UInt32, @name : String)
      @fields = Hash(String, Int32).new
      @field_types = Hash(String, String).new
      @methods = Hash(String, Crystal::Def).new
      @method_return_types = Hash(String, String).new
      @class_fields = Hash(String, Int32).new
      @class_methods = Hash(String, Crystal::Def).new
    end

    def field_index(name : String) : Int32
      clean = name.starts_with?("@") ? name[1..-1] : name
      if idx = @fields[clean]?
        idx
      else
        idx = @fields.size
        @fields[clean] = idx
        idx
      end
    end

    def ancestor_ids(all_classes : Hash(String, ClassInfo)) : Array(UInt32)
      res = [@class_id] + @included_module_ids
      if sc_name = @superclass_name
        if sc_info = all_classes[sc_name]?
          res += sc_info.ancestor_ids(all_classes)
        end
      end
      res.uniq
    end
  end
end
