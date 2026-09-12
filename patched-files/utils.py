import asyncio
from os import makedirs
from os.path import join, exists

settings_dir = '/var/lib/ofono2mm'
settings_file = join(settings_dir, 'settings.conf')

def async_retryable(times=0):
    """
    Decorator that allows to retry the given function n times.

    Usage:

    @async_retryable(5)
    async def fail():
        raise Exception("This function will be tried five times!")

    If times is 0 (default), the function will be retried indefinitely.
    """

    def decorator(func):
            async def wrapper(*args, **kwargs):
                    current_try = 0
                    while times == 0 or current_try < times:
                            try:
                                    result = await func(*args, **kwargs)
                            except Exception:
                                    if current_try == times-1:
                                            raise

                                    # print("Trying again, error was %s" % e)
                                    await asyncio.sleep(5)

                                    current_try += 1
                            else:
                                    return result

            return wrapper

    return decorator

def save_setting(key, value):
    makedirs(settings_dir, exist_ok=True)

    settings = parse_settings()

    settings[key] = value

    with open(settings_file, 'w', encoding='utf-8') as file:
        for k, v in settings.items():
            file.write(f"{k}: {v}\n")

def read_setting(key, default=False):
    settings = parse_settings()
    return str(settings.get(key, default))

def parse_settings():
    settings = {}
    if exists(settings_file):
        with open(settings_file, 'r', encoding='utf-8') as file:
            for line in file:
                if ':' in line:
                    k, v = line.strip().split(':', 1)
                    settings[k] = v.strip()
    return settings

def netmask_to_prefix(netmask, default=32):
    """
    Convert a dotted-quad netmask as reported by oFono ("255.255.255.0")
    into a CIDR prefix length. Returns `default` if it cannot be parsed.

    Without this, Ip4Config carries no "prefix" key and NetworkManager
    falls back to 0, which configures the address as a /0.
    """
    try:
        octets = [int(o) for o in str(netmask).strip().split('.')]
    except (AttributeError, ValueError):
        return default

    if len(octets) != 4 or any(o < 0 or o > 255 for o in octets):
        return default

    value = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
    prefix = 0
    seen_zero = False
    for i in range(31, -1, -1):
        if value & (1 << i):
            if seen_zero:
                # Non-contiguous mask, not something we can express as a prefix.
                return default
            prefix += 1
        else:
            seen_zero = True

    # A /0 is never a meaningful netmask here and is exactly the broken
    # value we are trying to avoid handing to NetworkManager.
    return prefix if prefix else default
