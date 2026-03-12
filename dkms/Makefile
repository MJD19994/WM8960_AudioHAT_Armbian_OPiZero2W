snd-soc-wm8960-objs := wm8960.o
obj-m += snd-soc-wm8960.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

.PHONY: all clean

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
