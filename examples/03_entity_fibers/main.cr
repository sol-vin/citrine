require "citrine"

Citrine.init_window(640, 448, "03 Entity Fibers - Citrine PS2")
Citrine.set_target_fps(60)

enemy_pos = Vector2.new(100.0, 200.0)
patrol_dir = 1.0

Citrine.main_loop do
  # Entity AI patrol logic
  if patrol_dir > 0.0
    enemy_pos.x += 2.0
    if enemy_pos.x > 500.0
      patrol_dir = -1.0
    end
  else
    enemy_pos.x -= 2.0
    if enemy_pos.x < 100.0
      patrol_dir = 1.0
    end
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  # Draw patrol platform
  Citrine.draw_rectangle(80, 250, 460, 20, Color::Gray)

  # Draw patrolling entity
  Citrine.draw_rectangle(enemy_pos.x, enemy_pos.y, 40, 50, Color::Red)
  Citrine.draw_circle(enemy_pos.x + 20.0, enemy_pos.y + 15.0, 8.0, Color::Yellow)

  Citrine.draw_text("Entity Patrol Scripting Demo", 40, 40, 16, Color::White)
  Citrine.draw_text("Patrolling entity smoothly across platform", 40, 70, 14, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
