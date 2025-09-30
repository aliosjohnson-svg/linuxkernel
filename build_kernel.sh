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

# === Get and Integrate AIC8800 Driver ===
echo "Cloning AIC8800 driver source..."
AIC_DRIVER_DIR=${BUILD_DIR}/aic8800-wifi
AIC_DRIVER_GIT_URL="https://github.com/aliosjohnson-svg/aic8800-wifi.git"
git clone --depth 1 ${AIC_DRIVER_GIT_URL} ${AIC_DRIVER_DIR}

echo "--> Integrating AIC8800 driver into kernel source..."
DRIVER_TARGET_DIR=${KERNEL_DIR}/drivers/net/wireless/aic8800
mkdir -p ${DRIVER_TARGET_DIR}
cp -r ${AIC_DRIVER_DIR}/SDIO/driver_fw/driver/aic8800/* ${DRIVER_TARGET_DIR}/

# Link driver into build system
echo "--> Patching Kernel Kconfig and Makefile..."
WIRELESS_KCONFIG=${KERNEL_DIR}/drivers/net/wireless/Kconfig
NET_KCONFIG=${KERNEL_DIR}/drivers/net/Kconfig
NET_MAKEFILE=${KERNEL_DIR}/drivers/net/Makefile

# Ensure wireless directory and its Kconfig/Makefile exist
mkdir -p ${KERNEL_DIR}/drivers/net/wireless
if [ ! -f "${WIRELESS_KCONFIG}" ]; then
    echo "Creating new drivers/net/wireless/Kconfig..."
    echo 'menu "Wireless LAN"' > ${WIRELESS_KCONFIG}
    echo 'endmenu' >> ${WIRELESS_KCONFIG}
    if ! grep -q "drivers/net/wireless/Kconfig" "${NET_KCONFIG}"; then
        echo 'source "drivers/net/wireless/Kconfig"' >> ${NET_KCONFIG}
    fi
    if ! grep -q "wireless/" "${NET_MAKEFILE}"; then
        echo 'obj-y += wireless/' >> ${NET_MAKEFILE}
    fi
fi

# Add the source line to the end of the file
echo 'source "drivers/net/wireless/aic8800/Kconfig"' >> ${WIRELESS_KCONFIG}
echo 'obj-$(CONFIG_AIC_WLAN_SUPPORT) += aic8800/' >> ${KERNEL_DIR}/drivers/net/wireless/Makefile

# --- VERIFICATION STEP 1 --- #
echo "--> Verifying Kconfig patch..."
grep "aic8800" ${WIRELESS_KCONFIG} || (echo "FATAL: Kconfig patch verification failed!" && exit 1)
echo "Kconfig patch verified."


# === Build the Kernel ===
echo "Building kernel. This will take a long time..."
cd ${KERNEL_DIR}
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# Enable the AIC8800 WiFi driver options as built-in
echo "--> Enabling AIC8800 kernel modules..."
scripts/config --enable CONFIG_AIC_WLAN_SUPPORT
scripts/config --enable CONFIG_AIC8800_WLAN_SUPPORT
scripts/config --enable CONFIG_AIC8800_BTLPM_SUPPORT

# --- VERIFICATION STEP 2 --- #
echo "--> Verifying .config for AIC8800 modules..."
grep "CONFIG_AIC_WLAN_SUPPORT=y" .config || (echo "FATAL: Failed to enable CONFIG_AIC_WLAN_SUPPORT!" && exit 1)
grep "CONFIG_AIC8800_WLAN_SUPPORT=y" .config || (echo "FATAL: Failed to enable CONFIG_AIC8800_WLAN_SUPPORT!" && exit 1)
echo ".config verification passed."

# Regenerate .config with new options and dependencies
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

echo "--> Final .config state for AIC8800 (should be '=m'):"
grep "AIC" .config | cat

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)

# === Install Kernel Artifacts ===
echo "Installing kernel modules..."
rm -rf ${OUTPUT_DIR}
mkdir -p ${OUTPUT_DIR}
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_install INSTALL_MOD_PATH=${OUTPUT_DIR}

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
