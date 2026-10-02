require "../../src/stubs/citrine"

Citrine.init_window(640, 448, "09 Concurrency Showcase - Citrine PS2")
Citrine.set_target_fps(60)

# Bounded Channels for task queue and results
work_channel = Citrine::Channel(Int32).new(16)
result_channel = Citrine::Channel(Int32).new(16)

# Spawn Autonomous Worker Fiber 1
Citrine.spawn do
  while true
    if item = work_channel.try_receive
      result_channel.send(1)
    else
      Citrine.yield
    end
  end
end

# Spawn Autonomous Worker Fiber 2
Citrine.spawn do
  while true
    if item = work_channel.try_receive
      result_channel.send(2)
    else
      Citrine.yield
    end
  end
end

player_x = 320.0
player_y = 260.0
pulse_radius = 0.0

Citrine.main_loop do
  # D-Pad Controls for Player Avatar
  if Citrine.button_down?(Button::Up)
    player_y -= 3.0
    if player_y < 170.0
      player_y = 170.0
    end
  end
  if Citrine.button_down?(Button::Down)
    player_y += 3.0
    if player_y > 390.0
      player_y = 390.0
    end
  end
  if Citrine.button_down?(Button::Left)
    player_x -= 3.0
    if player_x < 70.0
      player_x = 70.0
    end
  end
  if Citrine.button_down?(Button::Right)
    player_x += 3.0
    if player_x > 570.0
      player_x = 570.0
    end
  end

  # Press Cross to dispatch concurrent task to worker fibers
  if Citrine.button_pressed?(Button::Cross)
    work_channel.send(1)
    pulse_radius = 12.0
  end

  # Drain completed results from worker fibers
  while res = result_channel.try_receive
    # Task processed by worker fiber
  end

  # Expand visual pulse wave
  if pulse_radius > 0.0
    pulse_radius += 2.0
    if pulse_radius > 70.0
      pulse_radius = 0.0
    end
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  # Title & System Info
  Citrine.draw_text("Citrine PS2 Concurrency & Worker Pool", 40, 20, 20, Color::White)
  Citrine.draw_text("Cooperative Fibers + Zero-GC CSP Bounded Channels", 40, 48, 14, Color::Yellow)

  # Telemetry Status Panel
  Citrine.draw_rectangle(40, 75, 560, 60, Color::DarkGray)
  Citrine.draw_text("Fibers: 3 Active (Main Loop + 2 Background Workers)", 60, 88, 14, Color::Green)
  Citrine.draw_text("Channel Ring Buffer: 16 Slots | Zero Dynamic Heap Allocation", 60, 110, 14, Color::White)

  # Arena Playfield Boundary
  Citrine.draw_rectangle(40, 145, 560, 4, Color::Gray)
  Citrine.draw_rectangle(40, 415, 560, 4, Color::Gray)
  Citrine.draw_rectangle(40, 145, 4, 270, Color::Gray)
  Citrine.draw_rectangle(596, 145, 4, 270, Color::Gray)

  # Draw Player Avatar
  Citrine.draw_rectangle(player_x - 16.0, player_y - 16.0, 32.0, 32.0, Color::Red)
  Citrine.draw_circle(player_x, player_y, 8.0, Color::Yellow)

  # Draw Concurrency Wave Pulse when jobs are dispatched
  if pulse_radius > 0.0
    Citrine.draw_circle(player_x, player_y, pulse_radius, Color::Blue)
    Citrine.draw_circle(player_x, player_y, pulse_radius - 4.0, Color::Black)
  end

  # Controls Legend
  Citrine.draw_text("D-PAD: Move Player | CROSS: Dispatch Concurrent Job to Fibers", 50, 425, 14, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
