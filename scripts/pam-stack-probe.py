#!/usr/bin/env python3
"""Authenticate against a PAM service read from any directory, through the real libpam.

pam_start_confdir() (Linux-PAM >= 1.4) loads SERVICE from CONFDIR, includes and
all, without root and without touching /etc. Every prompt is answered with an
empty string and counted; libpam's failure delay is replaced by a no-op so a
failing attempt returns at once.

Used by scripts/setup-fingerprint.sh to refuse a sudo stack libpam cannot load
(a parse error anywhere makes libpam refuse every sudo, correct password or not),
and by scripts/test-fingerprint.sh to run the installed stack with stand-in
modules.

Usage:
    pam-stack-probe.py --confdir DIR --service NAME [--user NAME] [--tty TTY] [--attempts N]

Prints one line and exits 0 when it ran:
    "<result of the last attempt> <prompts answered>"   e.g. "0 0", "7 2"
    "start:<code>"                                       pam_start_confdir refused
Exits 2 when it could not run: no libpam, no pam_start_confdir, or bad arguments.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import sys

PAM_TTY_ITEM = 3
PAM_FAIL_DELAY_ITEM = 10
PAM_PROMPT_ECHO_OFF = 1
PAM_PROMPT_ECHO_ON = 2
EXIT_COULD_NOT_RUN = 2
DEFAULT_PROBE_USER = "fingerprint-probe"


class PamMessage(ctypes.Structure):
    """struct pam_message."""

    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    """struct pam_response."""

    _fields_ = [("resp", ctypes.c_void_p), ("resp_retcode", ctypes.c_int)]


CONVERSATION_FUNCTION = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.POINTER(PamMessage)),
    ctypes.POINTER(ctypes.POINTER(PamResponse)), ctypes.c_void_p)
FAIL_DELAY_FUNCTION = ctypes.CFUNCTYPE(None, ctypes.c_int, ctypes.c_uint, ctypes.c_void_p)


class PamConversation(ctypes.Structure):
    """struct pam_conv."""

    _fields_ = [("conv", CONVERSATION_FUNCTION), ("appdata_ptr", ctypes.c_void_p)]


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    """Parse the command line; argparse exits 2 on a bad one."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--confdir", required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--user", default=DEFAULT_PROBE_USER)
    parser.add_argument("--tty", default="")
    parser.add_argument("--attempts", type=int, default=1)
    return parser.parse_args(argv)


def load_libraries() -> tuple[ctypes.CDLL, ctypes.CDLL]:
    """Load libpam and libc, or exit 2 when this libpam cannot read a confdir."""
    pam_path = ctypes.util.find_library("pam")
    libc_path = ctypes.util.find_library("c")
    if not pam_path or not libc_path:
        print("no libpam", file=sys.stderr)
        sys.exit(EXIT_COULD_NOT_RUN)
    libpam = ctypes.CDLL(pam_path)
    libc = ctypes.CDLL(libc_path)
    if not hasattr(libpam, "pam_start_confdir"):
        print("this libpam has no pam_start_confdir (Linux-PAM < 1.4)", file=sys.stderr)
        sys.exit(EXIT_COULD_NOT_RUN)
    libc.strdup.restype = ctypes.c_void_p
    libc.calloc.restype = ctypes.c_void_p
    return libpam, libc


def main(argv: list[str]) -> int:
    """Run the attempts and print the last result and the prompt count."""
    arguments = parse_arguments(argv)
    libpam, libc = load_libraries()
    prompt_count = 0

    def answer_every_message_empty(count, messages, responses, _appdata):
        """Answer each message with an empty string, in memory libpam frees."""
        nonlocal prompt_count
        block = libc.calloc(count, ctypes.sizeof(PamResponse))
        if not block:
            return 1
        answers = ctypes.cast(block, ctypes.POINTER(PamResponse))
        for i in range(count):
            if messages[i].contents.msg_style in (PAM_PROMPT_ECHO_OFF, PAM_PROMPT_ECHO_ON):
                prompt_count += 1
            answers[i].resp = libc.strdup(b"")
        responses[0] = answers
        return 0

    conversation_callback = CONVERSATION_FUNCTION(answer_every_message_empty)
    no_fail_delay = FAIL_DELAY_FUNCTION(lambda _retval, _usec, _appdata: None)
    conversation = PamConversation(conversation_callback, None)
    handle = ctypes.c_void_p()
    started = libpam.pam_start_confdir(
        arguments.service.encode(), arguments.user.encode(), ctypes.byref(conversation),
        arguments.confdir.encode(), ctypes.byref(handle))
    if started != 0:
        print(f"start:{started}")
        return 0
    libpam.pam_set_item(handle, PAM_FAIL_DELAY_ITEM, ctypes.cast(no_fail_delay, ctypes.c_void_p))
    if arguments.tty:
        libpam.pam_set_item(handle, PAM_TTY_ITEM, arguments.tty.encode())
    result = None
    for _attempt in range(arguments.attempts):
        result = libpam.pam_authenticate(handle, 0)
    libpam.pam_end(handle, 0)
    print(f"{result} {prompt_count}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
