CC=gcc
PARAM=6688128
ROOT_DIR=../..
CFLAGS=-O3 -march=native -mtune=native -Wall -Wextra -Wno-unused-function -Wno-unused-parameter -Wno-sign-compare -Wno-memset-elt-size -Iinclude -I$(ROOT_DIR)/include/common
LIBS=-ldl -lm
KATNUM ?= 5
PROFILE_FILE=$(ROOT_DIR)/results/profile/Profile_CM_6688128.txt
ERRORSTREAM_FILE=$(ROOT_DIR)/results/output/errorstream0_6688128.bin

BUILD_DIR=$(ROOT_DIR)/build/$(PARAM)
BIN_DIR=$(ROOT_DIR)/bin
TARGET=$(BIN_DIR)/decrypt_$(PARAM)

OBJECTS=$(BUILD_DIR)/Decrypt.o $(BUILD_DIR)/gf_13.o $(BUILD_DIR)/root_13.o $(BUILD_DIR)/util.o $(BUILD_DIR)/bm.o

.SILENT:

all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR) $(BIN_DIR) $(ROOT_DIR)/results/profile $(ROOT_DIR)/results/output

$(BUILD_DIR)/Decrypt.o: src/Decrypt.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/gf_13.o: $(ROOT_DIR)/src/common/gf_13.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/root_13.o: $(ROOT_DIR)/src/common/root_13.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/util.o: src/util.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/bm.o: $(ROOT_DIR)/src/common/bm.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJECTS)
	$(CC) $(CFLAGS) $(OBJECTS) -o $@ $(LIBS)

run: $(TARGET)
	$(TARGET) $(KATNUM) > $(PROFILE_FILE)
	echo "Profile details stored at: $(PROFILE_FILE)"
	echo "Output stream stored at:   $(ERRORSTREAM_FILE)"

clean:
	rm -f $(OBJECTS) $(TARGET) $(PROFILE_FILE) $(ERRORSTREAM_FILE)

.PHONY: all clean run
