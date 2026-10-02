# PCSX2 Process Management & CI Testing

Best practices for launching, monitoring, and cleanly terminating PCSX2 instances from automated scripts and test suites.

---

## 1. Process Lifecycle Challenges on Windows

Modern PCSX2 (`pcsx2-qt.exe`) utilizes multiple threads and helper child processes (audio servers, crash reporters, IPC stubs).

### Problem: Orphaned Processes & Locked Files
- Calling standard process termination (e.g. `Process#kill` or PowerShell `Stop-Process`) can kill the parent Qt window while leaving child background workers holding open file descriptors.
- A locked `.iso` file prevents subsequent test runs from overwriting or deleting test fixtures.

### Solution: Forceful Process Tree Teardown
Always terminate the full process tree using `taskkill`:
```powershell
taskkill /F /T /PID <process_id>
```
In Crystal / Ruby / Node runners:
```crystal
def self.kill_process_tree(pid : Int32)
  if HostOS.windows?
    Process.run("taskkill", ["/F", "/T", "/PID", pid.to_s]) rescue nil
  else
    Process.signal(Signal::TERM, pid) rescue nil
  end
end
```

---

## 2. Preventing ISO Concurrency Collisions

When executing test suites sequentially or concurrently:
1. **Never use static filenames**: E.g. avoid `test_output.iso`.
2. **Include Unique Identifiers**: Use process ID and timestamp counters:
   ```crystal
   temp_iso = "tmp_run_#{Process.pid}_#{Time.utc.to_unix_ms}.iso"
   ```
3. **Clean Up in `ensure` Blocks**: Always delete generated ISOs after emulator exit.

---

## 3. Headless Verification Pattern

A standard pattern for verifying whether an ELF runs without human interaction:

```crystal
def verify_elf_runs(iso_path : String, timeout_seconds : Int32 = 10) : Bool
  pcsx2_path = find_pcsx2_executable
  log_path = File.expand_path("~/Documents/PCSX2/logs/emulog.txt")
  initial_log_size = File.exists?(log_path) ? File.size(log_path) : 0_i64

  process = Process.new(
    pcsx2_path,
    ["-batch", "-fastboot", iso_path],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close
  )

  success = false
  deadline = Time.monotonic + timeout_seconds.seconds

  while Time.monotonic < deadline
    sleep 250.milliseconds
    if File.exists?(log_path) && File.size(log_path) > initial_log_size
      content = File.read(log_path)
      if content.includes?("is executing.") && content.includes?("Set GS CRTC configuration")
        success = true
        break
      end
    end
  end

ensure
  kill_process_tree(process.pid) if process && !process.terminated?
end
```
