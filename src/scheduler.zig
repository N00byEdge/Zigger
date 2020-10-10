const platform = @import("platform.zig");
const arch = @import("builtin").arch;
const vmm = @import("vmm.zig");
const log = @import("logger.zig").log;

const std = @import("std");

fn async_dummy() void {
  suspend {
    _ = @frame();
  }
}

const frame_align = @alignOf(@Frame(async_dummy));

pub const Task = struct {
  frame: anyframe->void,
  frame_bytes: []align(frame_align)u8,
  next_task: ?*Task,
  wants_to_exit: bool = false,
};

// A simple lock which can be taken by any execution flow, across task switches.
pub const MultitaskingLock = struct {
  taken: bool = false,

  pub fn try_lock(self: *MultitaskingLock) bool {
    return !@atomicRmw(bool, &self.taken, .Xchg, true, .AcqRel);
  }

  pub fn lock(self: *MultitaskingLock) void {
    while(!self.try_lock()) { platform.spin_hint(); }
  }

  pub fn unlock(self: *MultitaskingLock) void {
    std.debug.assert(self.taken);
    @atomicStore(bool, &self.taken, false, .Release);
  }
};

// Lock something to a specific task
// Cannot be used by the scheduler as it might be switching tasks
// pub const Mutex = struct {
//   owner: ?*Task = null,

//   pub fn try_lock(self: *Mutex) bool {

//   }
// };

// Just a simple round robin implementation
const TaskQueue = struct {
  first_task: ?*Task = null,
  last_task: ?*Task = null,
  lock: MultitaskingLock = .{},

  pub fn choose_next_task(self: *@This()) *Task {
    self.lock.lock();
    defer self.lock.unlock();

    while(self.first_task == null) {
      platform.spin_hint();
    }

    const task = self.first_task.?;

    if(self.last_task == task) {
      self.last_task = null;
      self.first_task = null;
    }
    else {
      self.first_task = task.next_task;
    }

    task.next_task = null;
    return task;
  }

  pub fn enqueue_task_front(self: *@This(), task: *Task) void {
    self.lock.lock();
    defer self.lock.unlock();

    if(self.first_task) |ft| {
      task.next_task = ft;
    } else {
      self.last_task = task;
    }
    self.first_task = task;
  }

  pub fn enqueue_task(self: *@This(), task: *Task) void {
    self.lock.lock();
    defer self.lock.unlock();

    task.next_task = null;

    if(self.first_task == null)
      self.first_task = task;

    if(self.last_task) |*lt|
      lt.*.next_task = task;

    self.last_task = task;
  }
};

pub var queue = TaskQueue{};

fn switch_task(next_task: *Task) void {
  platform.set_current_task(next_task);
}

fn task_main(task: *Task, func: anytype, args: anytype) void {
  suspend;

  defer exit_task();

  _ = @call(.{}, func, args) catch |err| {
    log("Task exited with error: {}!\n", .{err});
  };
}

// Creating a new task
pub fn make_task(func: anytype, args: anytype) !void {
  const task = try vmm.alloc_single(Task);
  errdefer vmm.free_single(task) catch unreachable;

  const frame_bytes = @alignCast(frame_align, try vmm.alloc_size(u8, @frameSize(task_main)));
  errdefer vmm.free_size(u8, frame_bytes) catch unreachable;

  task.frame = @asyncCall(frame_bytes, {}, task_main, .{task, func, args});

  queue.enqueue_task(task);
}

pub fn exit_task() noreturn {
  platform.get_current_task().wants_to_exit = true;
  suspend;
  unreachable;
}

pub fn yield() void {
  suspend;
}

pub fn loop() noreturn {
  while(true) {
    const task = queue.choose_next_task();

    switch_task(task);

    resume task.frame;

    if(task.wants_to_exit) {
      vmm.free_size(u8, task.frame_bytes) catch unreachable;
      vmm.free_single(task) catch unreachable;
    }
    else {
      queue.enqueue_task(task);
    }
  }
}
