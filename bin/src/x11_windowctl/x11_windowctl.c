/*
 * Minimal X11 window controller for Kyodai's shuffler.
 *
 * Usage: x11_windowctl <minimize|raise> <pid>
 *
 * Finds a top-level window whose _NET_WM_PID matches the given PID and:
 *   minimize -> sets _NET_WM_STATE_HIDDEN
 *   raise    -> sends _NET_ACTIVE_WINDOW
 *
 * Exit codes:
 *   0 success
 *   1 window not found
 *   2 usage / X11 error
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>

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
	if (argc != 3) {
		fprintf(stderr, "Usage: %s <minimize|raise> <pid>\n", argv[0]);
		return 2;
	}

	const char *action = argv[1];
	pid_t target = (pid_t)atoi(argv[2]);
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
		fprintf(stderr, "No window found for PID %d\n", target);
		XCloseDisplay(dpy);
		return 1;
	}

	if (strcmp(action, "minimize") == 0) {
		send_client_message(dpy, win, net_wm_state, 1 /* _NET_WM_STATE_ADD */,
		                    net_wm_state_hidden);
	} else if (strcmp(action, "raise") == 0) {
		send_client_message(dpy, win, net_active_window, 2 /* source: pager */, 0);
		XRaiseWindow(dpy, win);
		XSetInputFocus(dpy, win, RevertToParent, CurrentTime);
	} else {
		fprintf(stderr, "Unknown action: %s\n", action);
		XCloseDisplay(dpy);
		return 2;
	}

	XFlush(dpy);
	XCloseDisplay(dpy);
	return 0;
}
