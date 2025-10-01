#!/bin/sh -e

set -x # Enable debug output for full transparency

# === Directories ===
BUILD_DIR=$(pwd)
KERNEL_DIR=${BUILD_DIR}/kernel
OUTPUT_DIR=${KERNEL_DIR}/output
PMAPORTS_DIR=${BUILD_DIR}/pmaports

# === Source Info ===
KERNEL_GIT_URL="https://github.com/msm8916-mainline/linux.git"
KERNEL_TAG="v6.6-msm8916"
PMAPORTS_GIT_URL="https://gitlab.com/postmarketOS/pmaports.git"
PMAPORTS_BRANCH="v24.06"

# === Clean up previous builds ===
echo "Cleaning up previous builds..."
rm -rf ${KERNEL_DIR} ${PMAPORTS_DIR}
mkdir -p ${KERNEL_DIR}

# === Get Kernel Source ===
echo "Cloning kernel source..."
git clone --depth 1 --branch ${KERNEL_TAG} ${KERNEL_GIT_URL} ${KERNEL_DIR}

# === Get AIC8800 Driver Source ===
echo "Cloning AIC8800 driver source..."
git clone https://github.com/geniuskidkanyi/aic8800.git --depth=1

# === Get Kernel Configuration by cloning pmaports (Robust method) ===
echo "Cloning pmaports repository to find kernel config..."
git clone --depth 1 --branch ${PMAPORTS_BRANCH} ${PMAPORTS_GIT_URL} ${PMAPORTS_DIR}

echo "Searching for kernel config file locally..."
CONFIG_FILE_PATH=$(find ${PMAPORTS_DIR} -type f -name "config-postmarketos-qcom-msm8916.aarch64" | head -n 1)

if [ -z "${CONFIG_FILE_PATH}" ]; then
    echo "FATAL: Could not find kernel config file in the cloned pmaports repository."
    exit 1
fi

echo "Found kernel config at: ${CONFIG_FILE_PATH}"
cp "${CONFIG_FILE_PATH}" "${KERNEL_DIR}/.config"

# === Build the Kernel ===
echo "Building kernel. This will take a long time..."
cd ${KERNEL_DIR}
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make KSRC=${KERNEL_DIR} M=${BUILD_DIR}/aic8800/src ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)

# === Install Kernel Artifacts ===
echo "Installing kernel modules..."
rm -rf ${OUTPUT_DIR}
mkdir -p ${OUTPUT_DIR}
make KSRC=${KERNEL_DIR} M=${BUILD_DIR}/aic8800_linux_drvier ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- install INSTALL_MOD_PATH=${OUTPUT_DIR}

# === Copy Kernel Image and Device Trees ===
echo "Copying kernel image and device tree blobs..."
mkdir -p ${OUTPUT_DIR}/boot/dtbs/qcom
cp arch/arm64/boot/Image ${OUTPUT_DIR}/boot/vmlinuz
cp arch/arm64/boot/dts/qcom/msm8916-*.dtb ${OUTPUT_DIR}/boot/dtbs/qcom/

# === Prepare Kernel Source for AIC8800 Driver Build ===
echo "Creating symlink for kernel source for driver compilation..."
mkdir -p ${OUTPUT_DIR}/usr/src/
mkdir -p ${OUTPUT_DIR}/opt/kernel_source
echo "DEBUG: Contents of KERNEL_DIR (${KERNEL_DIR}):"
ls -la ${KERNEL_DIR}
echo "DEBUG: Contents of target directory before rsync:"
ls -la ${OUTPUT_DIR}/opt/kernel_source
rsync -a --exclude 'output' ${KERNEL_DIR}/ ${OUTPUT_DIR}/opt/kernel_source/
echo "DEBUG: Contents of target directory after rsync:"
ls -la ${OUTPUT_DIR}/opt/kernel_source

# === Final Cleanup ===
echo "Cleaning up pmaports directory..."
rm -rf ${PMAPORTS_DIR}

echo "Kernel build complete. Output is in ${OUTPUT_DIR}"

# === Build and Install External AIC8800 Driver via DKMS ===
echo "Building and installing AIC8800 external module via DKMS..."

# Copy driver source to the dkms source directory
DRIVER_VERSION=$(grep 'PACKAGE_VERSION' ${BUILD_DIR}/aic8800/src/dkms.conf | cut -d '"' -f 2)
sudo cp -R ${BUILD_DIR}/aic8800/src /usr/src/aic8800-${DRIVER_VERSION}

# Add, build, and install the module with DKMS
dkms add -m aic8800 -v ${DRIVER_VERSION}
dkms build -m aic8800 -v ${DRIVER_VERSION} --kernelsourcedir ${KERNEL_DIR} --dkms-source-tree ${BUILD_DIR}/aic8800/src
dkms install -m aic8800 -v ${DRIVER_VERSION} --kernelsourcedir ${KERNEL_DIR} --dkms-source-tree ${BUILD_DIR}/aic8800/src --force

# Manually copy the installed module to the output directory for packaging
find /lib/modules/${KERNEL_DIR##*/}/ -name "aic*.ko" -exec cp {} ${OUTPUT_DIR}/lib/modules/${KERNEL_DIR##*/}/extra/ \;
