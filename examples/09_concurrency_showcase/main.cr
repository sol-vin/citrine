require "citrine"
require "citrine/inputmap"

# 09 Concurrency Showcase - Citrine PS2
# Demonstrates: Bounded Channel message passing (Citrine::Channel),
# cooperative worker thread pools, and queue telemetry on Sony PlayStation 2 EE

input_map do
  action :burst_jobs, Button::Cross, port: 0
  action :reset_stats, Button::Triangle, port: 0
end

Citrine.init_window(640, 448, "09 Concurrency Showcase - Citrine PS2")
Citrine.set_target_fps(60)

# Bounded Channels (16-slot FIFO queues)
work_channel = Citrine::Channel(Int32).new(16)
result_channel = Citrine::Channel(Int32).new(16)

# Autonomous Worker Fiber 1: Compute Engine
Citrine.spawn do
  while true
    if item = work_channel.try_receive
      # Simulate worker task transformation
      result_channel.send(item * 2)
    else
      Citrine.yield
    end
  end
end

# Autonomous Worker Fiber 2: Telemetry Processor
Citrine.spawn do
  while true
    if item = work_channel.try_receive
      # Secondary worker processing
      result_channel.send(item + 10)
    else
      Citrine.yield
    end
  end
end

player_x = 320.0_f32
player_y = 260.0_f32
total_dispatched = 0
total_processed = 0
auto_timer = 0
packet_step = 0

Citrine.main_loop do
  pad = Citrine.player(0)
  packet_step = (packet_step + 3) % 200

  # Interactive Avatar Navigation
  if pad.button_down?(Button::Up)
    player_y = Math.max(player_y - 3.5_f32, 170.0_f32)
  end
  if pad.button_down?(Button::Down)
    player_y = Math.min(player_y + 3.5_f32, 380.0_f32)
  end
  if pad.button_down?(Button::Left)
    player_x = Math.max(player_x - 3.5_f32, 60.0_f32)
  end
  if pad.button_down?(Button::Right)
    player_x = Math.min(player_x + 3.5_f32, 580.0_f32)
  end

  # Autonomous background task generation (continuous concurrency pipeline)
  auto_timer = (auto_timer + 1) % 18
  if auto_timer == 0 && work_channel.count < work_channel.capacity
    work_channel.send(total_dispatched + 1)
    total_dispatched += 1
  end

  # Burst Work Tasks through Bounded Channel on Cross
  if Action.is_pressed?(Actions::BurstJobs) || pad.button_pressed?(Button::Cross)
    5.times do |i|
      if work_channel.count < work_channel.capacity
        work_channel.send(total_dispatched + 1)
        total_dispatched += 1
      end
    end
  end

  if Action.is_pressed?(Actions::ResetStats) || pad.button_pressed?(Button::Triangle)
    total_dispatched = 0
    total_processed = 0
  end

  # Drain completed items from result channel
  while item = result_channel.try_receive
    total_processed += 1
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color.new(12_u8, 14_u8, 24_u8, 255_u8))

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 38, Color::Blue)
  Citrine.draw_text("CITRINE PS2: ASYNCHRONOUS CHANNEL CONCURRENCY", 60, 10, 17, Color::White)

  # --- Channel Queue Telemetry Panel ---
  Citrine.draw_rectangle(40, 55, 560, 95, Color::DarkGray)
  Citrine.draw_rectangle(42, 57, 556, 91, Color::Black)
  Citrine.draw_text("Bounded Synchronization Channels (FIFO Ring Buffers):", 55, 68, 13, Color::Yellow)

  # Work Channel Queue Level
  Citrine.draw_text("Work Queue:   #{work_channel.count} / #{work_channel.capacity}", 55, 92, 12, Color::White)
  bar_w1 = (work_channel.count * 180) // work_channel.capacity
  Citrine.draw_rectangle(220, 92, 180, 14, Color::DarkGray)
  Citrine.draw_rectangle(220, 92, bar_w1, 14, Color::Cyan)

  # Result Channel Queue Level
  Citrine.draw_text("Result Queue: #{result_channel.count} / #{result_channel.capacity}", 55, 116, 12, Color::White)
  bar_w2 = (result_channel.count * 180) // result_channel.capacity
  Citrine.draw_rectangle(220, 116, 180, 14, Color::DarkGray)
  Citrine.draw_rectangle(220, 116, bar_w2, 14, Color::Green)

  Citrine.draw_text("Tasks Sent: #{total_dispatched}", 430, 92, 12, Color::Yellow)
  Citrine.draw_text("Processed:  #{total_processed}", 430, 116, 12, Color::Green)

  # --- Worker Processing Stage Arena ---
  Citrine.draw_rectangle(40, 160, 560, 220, Color::DarkGray)
  Citrine.draw_rectangle(42, 162, 556, 216, Color::Black)

  # Worker Nodes with activity glow
  w1_active = work_channel.count > 0 || (packet_step % 40 < 20)
  w1_col = w1_active ? Color::Cyan : Color.new(0_u8, 120_u8, 160_u8, 255_u8)
  Citrine.draw_rectangle(100, 190, 120, 48, w1_col)
  Citrine.draw_text("WORKER 1", 120, 206, 13, Color::Black)
  Citrine.draw_circle(112, 198, 4.0_f32, w1_active ? Color::Green : Color::DarkGray)

  w2_active = result_channel.count > 0 || ((packet_step + 20) % 40 < 20)
  w2_col = w2_active ? Color::Magenta : Color.new(140_u8, 0_u8, 140_u8, 255_u8)
  Citrine.draw_rectangle(420, 190, 120, 48, w2_col)
  Citrine.draw_text("WORKER 2", 440, 206, 13, Color::Black)
  Citrine.draw_circle(432, 198, 4.0_f32, w2_active ? Color::Green : Color::DarkGray)

  # Connecting Channel Bus Lines
  Citrine.draw_line(220, 214, 420, 214, Color::Gray)
  Citrine.draw_line(160, 238, 160, 280, Color::DarkGray)
  Citrine.draw_line(480, 238, 480, 280, Color::DarkGray)
  Citrine.draw_line(160, 280, 480, 280, Color::DarkGray)

  # Animated Traveling Task Packets along the bus lines
  pkt1_x = 220 + ((packet_step * 2) % 200)
  Citrine.draw_circle(pkt1_x, 214, 4.0_f32, Color::Yellow)
  pkt2_x = 480 - ((packet_step * 2) % 320)
  if pkt2_x >= 160
    Citrine.draw_circle(pkt2_x, 280, 4.0_f32, Color::Green)
  end

  # Interactive Dispatcher Avatar with subtle idle hover
  bob = (packet_step % 30 < 15 ? 1 : -1)
  ix = player_x.to_i32
  iy = player_y.to_i32 + bob
  Citrine.draw_rectangle(ix - 16, iy - 16, 32, 32, Color::Yellow)
  Citrine.draw_circle(ix, iy, 6.0_f32, Color::Red)
  Citrine.draw_text("DISPATCHER", ix - 32, iy + 20, 10, Color::White)

  # Footer Controls
  Citrine.draw_rectangle(40, 390, 560, 44, Color::DarkGray)
  Citrine.draw_rectangle(42, 392, 556, 40, Color::Black)
  Citrine.draw_text("CROSS: Burst 5 Tasks | TRIANGLE: Reset | D-PAD: Move Dispatcher", 55, 405, 12, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
