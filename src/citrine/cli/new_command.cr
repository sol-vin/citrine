require "file_utils"

module Citrine
  module CLI
    class NewCommand
      def self.run(args : Array(String))
        project_name = args.first?
        unless project_name
          puts "Usage: citrine new <project_name>"
          exit(1)
        end

        if Dir.exists?(project_name)
          puts "Error: Directory '#{project_name}' already exists."
          exit(1)
        end

        Dir.mkdir_p(File.join(project_name, "src"))
        Dir.mkdir_p(File.join(project_name, "assets"))

        # Write template main.cr
        template = <<-CRYSTAL
        require "citrine"

        Citrine.init_window(640, 448, "#{project_name}")
        Citrine.set_target_fps(60)

        pos = Vector2.new(320.0, 224.0)
        speed = 3.0

        Citrine.main_loop do
          # Controller input
          if Citrine.button_down?(Button::Right)
            pos.x += speed
          elsif Citrine.button_down?(Button::Left)
            pos.x -= speed
          end

          if Citrine.button_down?(Button::Down)
            pos.y += speed
          elsif Citrine.button_down?(Button::Up)
            pos.y -= speed
          end

          # Rendering
          Citrine.begin_drawing
          Citrine.clear_background(Color::Black)

          Citrine.draw_rectangle(pos.x, pos.y, 40, 40, Color::Red)
          Citrine.draw_text("Welcome to #{project_name} on PS2!", 20, 20, 16, Color::Yellow)

          Citrine.end_drawing
        end

        Citrine.close_window
        CRYSTAL

        File.write(File.join(project_name, "src", "main.cr"), template)

        puts "[Citrine] Created new PS2 game project '#{project_name}'!"
        puts "To start developing:"
        puts "  cd #{project_name}"
        puts "  citrine run src/main.cr --watch"
      end
    end
  end
end
