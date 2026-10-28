"""Launch the installed probe in the background, then disconnect from the phone.

uv run --with pymobiledevice3==11.44.0 python launch_probe.py --udid DEVICE_UDID

Requires a paired phone with Developer Mode and a mounted Developer Disk Image.
Uses a temporary userspace developer-service tunnel; no root or server is needed.
"""
import argparse
import sys

from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
from pymobiledevice3.__main__ import main

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--udid', required=True, help='Exact target phone UDID')
parser.add_argument('--benchmark-seconds', type=int, choices=range(1,301), metavar='1..300', help='Run capture and alternating Home Screen swipes for this many seconds')
parser.add_argument('--native', action='store_true', help="Use Apple's existing device tunnel (including Wi-Fi), instead of a USB userspace tunnel")
parser.add_argument('--no-capture', action='store_true', help='Benchmark only: disable screenshots, JPEG conversion, and image writes')
parser.add_argument('--gesture-size', type=float, nargs=2, metavar=('WIDTH','HEIGHT'), help='Previously verified display dimensions in points; required with --no-capture')
parser.add_argument('--swipe-interval', type=float, default=0, help='Minimum seconds between swipe starts; zero keeps the original unpaced driver')
args = parser.parse_args()
if args.no_capture and (not args.benchmark_seconds or not args.gesture_size or min(args.gesture_size) <= 0):
    parser.error('--no-capture requires --benchmark-seconds and a positive --gesture-size')
if args.swipe_interval < 0:
    parser.error('--swipe-interval must be nonnegative')

# Reuse the library's device/tunnel lifecycle while supplying the launch option
# its CLI does not yet expose. This changes only this short-lived Python process.
original_launch = ProcessControl.launch
async def launch_in_background(self, *positional, **options):
    if args.benchmark_seconds:
        options['environment'] = {**(options.get('environment') or {}), 'PHANTOM_BENCHMARK_SECONDS': str(args.benchmark_seconds)}
        options['environment']['PHANTOM_CAPTURE_DISABLED'] = '1' if args.no_capture else '0'
        options['environment']['PHANTOM_SWIPE_INTERVAL'] = str(args.swipe_interval)
        if args.gesture_size:
            options['environment']['PHANTOM_GESTURE_WIDTH'] = str(args.gesture_size[0])
            options['environment']['PHANTOM_GESTURE_HEIGHT'] = str(args.gesture_size[1])
    options['extra_options'] = {
        **(options.get('extra_options') or {}),
        'ActivateSuspended': True,
    }
    return await original_launch(self, *positional, **options)

ProcessControl.launch = launch_in_background
sys.argv = [
    'pymobiledevice3', 'developer', 'dvt', 'launch', '--native' if args.native else '--userspace',
    '--udid', args.udid, 'me.sophiaxu.phantomprobe.xctrunner',
]
try:
    sys.exit(main())
finally:
    ProcessControl.launch = original_launch
