/*
 * Minimal X11 window controller for Kyodai's shuffler.
 *
 * Usage: x11_windowctl <minimize|raise|hide|show> <pid> [name_hint]
 *
 * Finds a top-level window whose _NET_WM_PID matches the given PID and:
 *   minimize -> sets _NET_WM_STATE_HIDDEN
 *   raise    -> sends _NET_ACTIVE_WINDOW
 *   hide     -> XUnmapWindow (bypasses WM policy; works on frozen clients
 *               and compositors like gamescope that ignore EWMH hints)
 *   show     -> XMapRaised + _NET_ACTIVE_WINDOW
 *
 * Many minimal X11 clients (RetroArch, SDL-less toolkits) never set
 * _NET_WM_PID. When the pid lookup finds nothing and a name_hint is given,
 * falls back to the first window whose WM_CLASS or title contains the hint
 * (case-insensitive).
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

static int find_window(Display *dpy, Window root, Window *out_win, pid_t target)
{
	Window root_return, parent;
	Window *children = NULL;
	unsigned int nchildren = 0;
	int found = 0;

	if (XQueryTree(dpy, root, &root_return, &parent, &children, &nchildren) == 0)
		return 0;

	for (unsigned int i = 0; i < nchildren && !found; i++) {
		Atom type;
		int format;
		unsigned long nitems, bytes_after;
		unsigned char *prop = NULL;

		if (XGetWindowProperty(dpy, children[i], net_wm_pid, 0, 1, False,
		                       XA_CARDINAL, &type, &format, &nitems,
		                       &bytes_after, &prop) == Success && prop) {
			if (nitems >= 1) {
				pid_t pid = (pid_t) *((unsigned long *)prop);
				if (pid == target) {
					*out_win = children[i];
					found = 1;
				}
			}
			XFree(prop);
		}

		if (!found)
			found = find_window(dpy, children[i], out_win, target);
	}

	if (children)
		XFree(children);

	return found;
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

/* First window (depth-first) whose WM_CLASS res_name/res_class or WM_NAME
 * contains the hint. WM_CLASS matches are preferred over title matches. */
static int find_window_by_hint(Display *dpy, Window win, Window *out_win,
                               const char *hint, int depth)
{
	XClassHint class_hint;
	if (XGetClassHint(dpy, win, &class_hint)) {
		int match = contains_ci(class_hint.res_name, hint) ||
		            contains_ci(class_hint.res_class, hint);
		if (class_hint.res_name)
			XFree(class_hint.res_name);
		if (class_hint.res_class)
			XFree(class_hint.res_class);
		if (match) {
			*out_win = win;
			return 1;
		}
	}
	if (depth > 0) {
		char *name = NULL;
		if (XFetchName(dpy, win, &name) && name) {
			int match = contains_ci(name, hint);
			XFree(name);
			if (match) {
				*out_win = win;
				return 1;
			}
		}
	}

	Window root_return, parent;
	Window *children = NULL;
	unsigned int nchildren = 0;
	if (XQueryTree(dpy, win, &root_return, &parent, &children, &nchildren) == 0)
		return 0;
	int found = 0;
	for (unsigned int i = 0; i < nchildren && !found; i++)
		found = find_window_by_hint(dpy, children[i], out_win, hint, 0);
	if (children)
		XFree(children);
	return found;
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
	if (argc < 3 || argc > 4) {
		fprintf(stderr, "Usage: %s <minimize|raise|hide|show> <pid> [name_hint]\n", argv[0]);
		return 2;
	}

	const char *action = argv[1];
	pid_t target = (pid_t)atoi(argv[2]);
	const char *hint = (argc == 4) ? argv[3] : NULL;
	if (target <= 0) {
		fprintf(stderr, "Invalid PID: %s\n", argv[2]);
		return 2;
	}

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

	Window win;
	if (!find_window(dpy, root, &win, target)) {
		if (!hint || !find_window_by_hint(dpy, root, &win, hint, 1)) {
			fprintf(stderr, "No window found for PID %d\n", target);
			XCloseDisplay(dpy);
			return 1;
		}
		fprintf(stderr, "PID lookup failed for %d; matched window by name hint '%s'\n",
		        target, hint);
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
	} else {
		fprintf(stderr, "Unknown action: %s\n", action);
		XCloseDisplay(dpy);
		return 2;
	}

	XFlush(dpy);
	XCloseDisplay(dpy);
	return 0;
}
