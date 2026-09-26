CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra
LDFLAGS ?= -lX11

TARGET = x11_windowctl

.PHONY: all clean

all: $(TARGET)

$(TARGET): x11_windowctl.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)
