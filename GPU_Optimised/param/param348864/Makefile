ARCH        ?= sm_86
NVCC        ?= nvcc
HOSTCC      ?= gcc
PARAM       := 348864
ROOT_DIR    := ../..
KATNUM      ?= 5
WRITE_ERRORSTREAM ?= 0

TARGET      := $(ROOT_DIR)/bin/decrypt_gpu_optimised_$(PARAM)
BUILD_DIR   := $(ROOT_DIR)/build/$(PARAM)
PROFILE_FILE:= $(ROOT_DIR)/results/profile/Profile_GPU_optimised_348864.txt
ERRORSTREAM_FILE:= $(ROOT_DIR)/results/output/errorstream0_348864.bin

COMMON_FLAGS := -O3 --use_fast_math -Xcompiler "-Wall,-Wextra"
CPP_DEFS     := -DKATNUM=$(KATNUM) -DWRITE_ERRORSTREAM=$(WRITE_ERRORSTREAM)
NVCCFLAGS    := -arch=$(ARCH) $(COMMON_FLAGS) -lineinfo $(CPP_DEFS)
CFLAGS       := -std=c11 -O3 -Wall -Wextra $(CPP_DEFS)
LIBS         := -lcudart -lnvToolsExt -lm

INC_FLAGS    := -Iinclude -I$(ROOT_DIR)/include/common

CU_OBJ := $(BUILD_DIR)/Decrypt.o
C_OBJS := $(BUILD_DIR)/util.o $(BUILD_DIR)/gf.o $(BUILD_DIR)/root.o
OBJS   := $(CU_OBJ) $(C_OBJS)

.SILENT:

.PHONY: all run output clean
all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR) $(ROOT_DIR)/bin $(ROOT_DIR)/results/profile $(ROOT_DIR)/results/output

$(CU_OBJ): src/cuda/Decrypt.cu | $(BUILD_DIR)
	mkdir -p $(dir $@)
	$(NVCC) $(NVCCFLAGS) $(INC_FLAGS) -c $< -o $@

$(BUILD_DIR)/util.o: src/host/util.c | $(BUILD_DIR)
	mkdir -p $(dir $@)
	$(HOSTCC) $(CFLAGS) $(INC_FLAGS) -c $< -o $@

$(BUILD_DIR)/gf.o: src/host/gf.c | $(BUILD_DIR)
	mkdir -p $(dir $@)
	$(HOSTCC) $(CFLAGS) $(INC_FLAGS) -c $< -o $@

$(BUILD_DIR)/root.o: src/host/root.c | $(BUILD_DIR)
	mkdir -p $(dir $@)
	$(HOSTCC) $(CFLAGS) $(INC_FLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(NVCC) -arch=$(ARCH) $(INC_FLAGS) $(COMMON_FLAGS) $(OBJS) -o $@ $(LIBS)

run:
	$(MAKE) --no-print-directory clean all ARCH=$(ARCH) KATNUM=$(KATNUM) WRITE_ERRORSTREAM=0
	$(TARGET) > $(PROFILE_FILE)
	echo "Profile details stored at: $(PROFILE_FILE)"

output:
	$(MAKE) --no-print-directory clean all ARCH=$(ARCH) KATNUM=$(KATNUM) WRITE_ERRORSTREAM=1
	$(TARGET) > $(PROFILE_FILE)
	echo "Output stream stored at:   $(ERRORSTREAM_FILE)"
	echo "Profile details stored at: $(PROFILE_FILE)"

clean:
	rm -f $(OBJS) $(TARGET) $(PROFILE_FILE) $(ERRORSTREAM_FILE)
