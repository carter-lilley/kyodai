/*
 * Minimal X11 window controller for Kyodai's shuffler.
 *
 * Usage: x11_windowctl <minimize|raise|hide|show|find> <pid|xid:HEX> [name_hint]
 *
 * Target selection:
 *   xid:HEX  -> use that window directly, no lookup (unambiguous; the
 *               shuffler captures an XID per game at launch via 'find')
 *   pid+hint -> first window whose _NET_WM_PID matches AND whose WM_CLASS or
 *               title contains the hint (exact for multi-window apps)
 *   pid      -> first window whose _NET_WM_PID matches
 *   hint     -> NEWEST window (highest XID) whose WM_CLASS or title contains
 *               the hint. Many minimal X11 clients (RetroArch) never set
 *               _NET_WM_PID, and several instances can be alive at once
 *               (suspended games); the newest one is the just-launched game.
 *               Matching is case-insensitive.
 *
 * Actions:
 *   minimize -> sets _NET_WM_STATE_HIDDEN
 *   raise    -> sends _NET_ACTIVE_WINDOW + XRaiseWindow + XSetInputFocus
 *   hide     -> XUnmapWindow (bypasses WM policy; works on frozen clients
 *               and compositors like gamescope that ignore EWMH hints)
 *   show     -> XMapRaised + _NET_ACTIVE_WINDOW
 *   find     -> prints the matched window's XID (hex) to stdout
 *
 * Exit codes:
 *   0 success
 *   1 window not found
 *   2 usage / X11 error
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>

static Atom net_wm_pid;
static Atom net_wm_state;
static Atom net_wm_state_hidden;
static Atom net_active_window;

static int window_pid(Display *dpy, Window win, pid_t *out)
{
	Atom type;
	int format;
	unsigned long nitems, bytes_after;
	unsigned char *prop = NULL;

	if (XGetWindowProperty(dpy, win, net_wm_pid, 0, 1, False,
	                       XA_CARDINAL, &type, &format, &nitems,
	                       &bytes_after, &prop) != Success || !prop)
		return 0;
	int ok = 0;
	if (nitems >= 1) {
		*out = (pid_t) *((unsigned long *)prop);
		ok = 1;
	}
	XFree(prop);
	return ok;
}

static int contains_ci(const char *hay, const char *needle)
{
	if (!hay || !needle || !*needle)
		return 0;
	size_t nlen = strlen(needle);
	for (const char *p = hay; *p; p++) {
		size_t i = 0;
		while (i < nlen && p[i] &&
		       tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i]))
			i++;
		if (i == nlen)
			return 1;
	}
	return 0;
}

/* WM_CLASS res_name/res_class or WM_NAME contains the hint (case-insensitive). */
static int window_matches_hint(Display *dpy, Window win, const char *hint)
{
	XClassHint class_hint;
	if (XGetClassHint(dpy, win, &class_hint)) {
		int match = contains_ci(class_hint.res_name, hint) ||
		            contains_ci(class_hint.res_class, hint);
		if (class_hint.res_name)
			XFree(class_hint.res_name);
		if (class_hint.res_class)
			XFree(class_hint.res_class);
		if (match)
			return 1;
	}
	char *name = NULL;
	if (XFetchName(dpy, win, &name) && name) {
		int match = contains_ci(name, hint);
		XFree(name);
		if (match)
			return 1;
	}
	return 0;
}

struct match_state {
	pid_t pid;
	const char *hint;
	Window pid_hint_win; /* first window matching both pid and hint */
	Window pid_win;      /* first window matching pid */
	Window hint_win;     /* newest (highest XID) window matching hint */
};

static void collect_matches(Display *dpy, Window win, struct match_state *st)
{
	pid_t pid = 0;
	int has_pid = window_pid(dpy, win, &pid);
	int hint_match = st->hint && window_matches_hint(dpy, win, st->hint);

	if (has_pid && pid == st->pid) {
		if (hint_match && st->pid_hint_win == None)
			st->pid_hint_win = win;
		if (st->pid_win == None)
			st->pid_win = win;
	}
	/* XIDs increase per client connection, so a newer emulator instance has
	 * higher window IDs than suspended ones that stay connected. */
	if (hint_match && (st->hint_win == None || win > st->hint_win))
		st->hint_win = win;

	Window root_return, parent;
	Window *children = NULL;
	unsigned int nchildren = 0;
	if (XQueryTree(dpy, win, &root_return, &parent, &children, &nchildren) == 0)
		return;
	for (unsigned int i = 0; i < nchildren; i++)
		collect_matches(dpy, children[i], st);
	if (children)
		XFree(children);
}

static Window parse_xid(const char *s)
{
	if (strncmp(s, "xid:", 4) == 0)
		s += 4;
	return (Window)strtoul(s, NULL, 16);
}

static void send_client_message(Display *dpy, Window win, Atom msg_type,
                                Atom data0, Atom data1)
{
	XEvent ev;
	memset(&ev, 0, sizeof(ev));
	ev.xclient.type = ClientMessage;
	ev.xclient.serial = 0;
	ev.xclient.send_event = True;
	ev.xclient.display = dpy;
	ev.xclient.window = win;
	ev.xclient.message_type = msg_type;
	ev.xclient.format = 32;
	ev.xclient.data.l[0] = data0;
	ev.xclient.data.l[1] = data1;
	ev.xclient.data.l[2] = 0;
	ev.xclient.data.l[3] = 0;
	ev.xclient.data.l[4] = 0;

	Window root = DefaultRootWindow(dpy);
	XSendEvent(dpy, root, False,
	           SubstructureRedirectMask | SubstructureNotifyMask, &ev);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "Usage: %s <minimize|raise|hide|show|find|xkill> <pid|xid:HEX> [name_hint] | %s active | %s set-transient <xid:CHILD> <xid:PARENT>\n", argv[0], argv[0], argv[0]);
		return 2;
	}

	const char *action = argv[1];

	Display *dpy = XOpenDisplay(NULL);
	if (!dpy) {
		fprintf(stderr, "Failed to open X display\n");
		return 2;
	}

	int screen = DefaultScreen(dpy);
	Window root = RootWindow(dpy, screen);

	net_wm_pid = XInternAtom(dpy, "_NET_WM_PID", False);
	net_wm_state = XInternAtom(dpy, "_NET_WM_STATE", False);
	net_wm_state_hidden = XInternAtom(dpy, "_NET_WM_STATE_HIDDEN", False);
	net_active_window = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);

	/* Prints the currently active window ("<xid> <title>" or "none"). */
	if (strcmp(action, "active") == 0) {
		Atom actual;
		int fmt;
		unsigned long nitems, after;
		unsigned char *prop = NULL;
		Window active = None;
		if (XGetWindowProperty(dpy, root, net_active_window, 0, 1, False,
		                       XA_WINDOW, &actual, &fmt, &nitems,
		                       &after, &prop) == Success && prop) {
			if (nitems >= 1)
				active = *((Window *)prop);
			XFree(prop);
		}
		if (active == None) {
			printf("none\n");
		} else {
			char *name = NULL;
			XFetchName(dpy, active, &name);
			printf("%lx %s\n", (unsigned long)active, name ? name : "");
			if (name)
				XFree(name);
		}
		XCloseDisplay(dpy);
		return 0;
	}

	/* Marks CHILD as a transient/dialog of PARENT (WM_TRANSIENT_FOR):
	 * compositors like gamescope draw dialogs above their parent window
	 * without any focus change. */
	if (strcmp(action, "set-transient") == 0) {
		if (argc != 4) {
			fprintf(stderr, "Usage: %s set-transient <xid:CHILD> <xid:PARENT>\n", argv[0]);
			XCloseDisplay(dpy);
			return 2;
		}
		Window child = parse_xid(argv[2]);
		Window parent = parse_xid(argv[3]);
		if (child == None || parent == None) {
			fprintf(stderr, "Invalid XID(s): %s %s\n", argv[2], argv[3]);
			XCloseDisplay(dpy);
			return 2;
		}
		XChangeProperty(dpy, child, XA_WM_TRANSIENT_FOR, XA_WINDOW, 32,
		                PropModeReplace, (unsigned char *)&parent, 1);
		XFlush(dpy);
		XCloseDisplay(dpy);
		return 0;
	}

	if (argc < 3 || argc > 4) {
		fprintf(stderr, "Usage: %s <minimize|raise|hide|show|find|xkill> <pid|xid:HEX> [name_hint]\n", argv[0]);
		XCloseDisplay(dpy);
		return 2;
	}

	const char *target_str = argv[2];
	const char *hint = (argc == 4) ? argv[3] : NULL;

	Window win = None;
	if (strncmp(target_str, "xid:", 4) == 0) {
		win = parse_xid(target_str);
		if (win == None) {
			fprintf(stderr, "Invalid XID: %s\n", target_str);
			XCloseDisplay(dpy);
			return 2;
		}
	} else {
		pid_t target = (pid_t)atoi(target_str);
		if (target <= 0) {
			fprintf(stderr, "Invalid PID: %s\n", target_str);
			XCloseDisplay(dpy);
			return 2;
		}
		struct match_state st = { target, hint, None, None, None };
		collect_matches(dpy, root, &st);
		if (st.pid_hint_win != None) {
			win = st.pid_hint_win;
		} else if (st.pid_win != None) {
			win = st.pid_win;
		} else if (st.hint_win != None) {
			win = st.hint_win;
			fprintf(stderr, "PID lookup failed for %d; matched newest window by name hint '%s'\n",
			        target, hint);
		} else {
			fprintf(stderr, "No window found for PID %d\n", target);
			XCloseDisplay(dpy);
			return 1;
		}
	}

	if (strcmp(action, "minimize") == 0) {
		send_client_message(dpy, win, net_wm_state, 1 /* _NET_WM_STATE_ADD */,
		                    net_wm_state_hidden);
	} else if (strcmp(action, "raise") == 0) {
		send_client_message(dpy, win, net_active_window, 2 /* source: pager */, 0);
		XRaiseWindow(dpy, win);
		XSetInputFocus(dpy, win, RevertToParent, CurrentTime);
	} else if (strcmp(action, "hide") == 0) {
		XUnmapWindow(dpy, win);
	} else if (strcmp(action, "show") == 0) {
		XMapRaised(dpy, win);
		send_client_message(dpy, win, net_active_window, 2 /* source: pager */, 0);
	} else if (strcmp(action, "find") == 0) {
		printf("%lx\n", (unsigned long)win);
	} else if (strcmp(action, "xkill") == 0) {
		/* Kills the X client that owns the window: the real emulator even
		 * when our tracked pid is a launcher wrapper. */
		XKillClient(dpy, win);
	} else {
		fprintf(stderr, "Unknown action: %s\n", action);
		XCloseDisplay(dpy);
		return 2;
	}

	XFlush(dpy);
	XCloseDisplay(dpy);
	return 0;
}
