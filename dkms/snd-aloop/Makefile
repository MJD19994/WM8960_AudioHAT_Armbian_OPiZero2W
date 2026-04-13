KERNELDIR ?= /lib/modules/$(shell uname -r)/build

obj-m += snd-aloop.o
snd-aloop-objs := aloop.o

all:
	$(MAKE) -C $(KERNELDIR) M=$(shell pwd) modules

clean:
	$(MAKE) -C $(KERNELDIR) M=$(shell pwd) clean

.PHONY: all clean
