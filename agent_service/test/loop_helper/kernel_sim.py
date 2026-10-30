"""Runs the supervisor's loop helper (its exact source, argv[1]) against a
simulated loop device, one scenario per run (argv[2], JSON), and prints the
helper's answer and the final binding. No device is touched.

The model follows the kernel (checked on 7.0): LOOP_CLR_FD only marks the
binding; it goes on the device's last close. Cleared by its only opener the
device runs down (GET_STATUS64 and open answer ENXIO); with another opener
it stays bound until that one closes too.

Scenario keys: op; start ('hold', 'image', 'foreign' or null); size (image
bytes); other_opener (sleeps until another opener closes; -1 never);
udev_after_clear (it opens the device during the run-down for that many
sleeps); open_in_rundown (open is allowed while running down);
steal_before_bind; steal_after_clear (another binder takes the device as
soon as the cleared binding is gone)."""
import contextlib, errno, fcntl, io, json, os, stat, struct, subprocess, sys, time, types
from unittest.mock import patch

code = open(sys.argv[1]).read()
sc = json.loads(sys.argv[2])
HOLD, IMAGE, FOREIGN = (7, 88), (1, 2), (9, 99)
NAMES = {HOLD: 'hold', IMAGE: 'image', FOREIGN: 'foreign', None: None}


class Kernel:
    def __init__(self):
        self.binding = {v: k for k, v in NAMES.items()}[sc.get('start')]
        self.pending = self.rundown = False
        self.size = sc.get('size', 0)
        self.fds, self.next, self.openers = {}, 100, 0
        self.other = sc.get('other_opener', 0)
        self.formats = self.sleeps = 0

    def settle(self):
        if self.pending and self.openers == 0 and self.other == 0:
            self.pending = self.rundown = False
            self.binding = FOREIGN if sc.get('steal_after_clear') else None

    def open(self, p, flags):
        if p.startswith('/dev/'):
            if self.rundown and not sc.get('open_in_rundown'):
                raise OSError(errno.ENXIO, 'running down')
            self.openers += 1
        self.next += 1
        self.fds[self.next] = p
        return self.next

    def close(self, fd):
        if self.fds.pop(fd).startswith('/dev/'):
            self.openers -= 1
            if self.pending and self.openers == 0 and sc.get('udev_after_clear'):
                self.other, sc['udev_after_clear'] = sc['udev_after_clear'], 0
                self.rundown = True
            self.settle()

    def sleep(self, s):
        self.sleeps += 1
        if self.other > 0:
            self.other -= 1
        self.settle()

    def fstat(self, fd):
        p = self.fds[fd]
        if p.startswith('/dev/'):
            return types.SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(7, 240))
        dev, ino = HOLD if p == '/hold.img' else IMAGE
        return types.SimpleNamespace(st_mode=stat.S_IFREG, st_dev=dev, st_ino=ino, st_size=self.size)

    def ioctl(self, d, op, arg=0):
        if op == 0x4C05:  # LOOP_GET_STATUS64
            if self.binding is None or self.rundown:
                raise OSError(errno.ENXIO, 'not bound')
            struct.pack_into('=QQ', arg, 0, *self.binding)
            if self.binding == FOREIGN:
                arg[56:72] = b'example_1.snap\0\0'
            return 0
        if op == 0x4C01:  # LOOP_CLR_FD
            if self.binding is None or self.pending:
                raise OSError(errno.ENXIO, 'not bound')
            self.pending = True
            self.rundown = self.openers == 1 and self.other == 0
            return 0
        if op == 0x4C00:  # LOOP_SET_FD
            if sc.get('steal_before_bind') and self.fds[arg] == '/disk.img':
                sc['steal_before_bind'] = False
                self.binding = FOREIGN
            if self.binding is not None or self.pending:
                raise OSError(errno.EBUSY, 'busy')
            self.binding = HOLD if self.fds[arg] == '/hold.img' else IMAGE
            return 0
        raise AssertionError(hex(op))

    def allocate(self, fd, off, size):
        self.size = size

    def command(self, args, **kw):
        self.formats += args[0] == 'mke2fs'
        return subprocess.CompletedProcess(args, 0, b'', b'')


k = Kernel()
argv = ['helper', sc['op'], '/dev/loop240', '1', '2']
if sc['op'] == 'prepare':
    argv += [str(128 << 20), '0', '1000', '1000']
out, code_ = io.StringIO(), None
with contextlib.redirect_stdout(out), \
        patch.object(os, 'open', k.open), patch.object(os, 'close', k.close), \
        patch.object(os, 'fstat', k.fstat), patch.object(os, 'posix_fallocate', k.allocate), \
        patch.object(os, 'statvfs', lambda p: types.SimpleNamespace(f_bavail=10 ** 9, f_frsize=4096)), \
        patch.object(fcntl, 'ioctl', k.ioctl), patch.object(subprocess, 'run', k.command), \
        patch.object(time, 'sleep', k.sleep), patch.object(sys, 'argv', argv), \
        patch.dict(os.environ, {'HOLD': '%d:%d' % HOLD}):
    try:
        exec(compile(code, 'loop-helper', 'exec'), {'__name__': '__main__'})
    except SystemExit as e:
        code_ = e.code
print(json.dumps({'exit': code_, 'answer': json.loads(out.getvalue()), 'binding': NAMES[k.binding],
                  'formats': k.formats, 'sleeps': k.sleeps, 'open': k.openers}))
