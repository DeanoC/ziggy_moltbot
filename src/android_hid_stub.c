#include <jni.h>

JNIEXPORT void JNICALL Java_org_libsdl_app_HIDDeviceManager_HIDDeviceRegisterCallback(
    JNIEnv* env, jobject thiz) {
    (void)env;
    (void)thiz;
}

JNIEXPORT void JNICALL Java_org_libsdl_app_HIDDeviceManager_HIDDeviceReleaseCallback(
    JNIEnv* env, jobject thiz) {
    (void)env;
    (void)thiz;
}

JNIEXPORT void JNICALL Java_org_libsdl_app_HIDDeviceManager_HIDDeviceConnected(
    JNIEnv* env, jobject thiz, jint device_id, jstring identifier, jint vendor_id, jint product_id,
    jstring serial_number, jint release_number, jstring manufacturer_string, jstring product_string,
    jint interface_number, jint interface_class, jint interface_subclass, jint interface_protocol) {
    (void)env;
    (void)thiz;
    (void)device_id;
    (void)identifier;
    (void)vendor_id;
    (void)product_id;
    (void)serial_number;
    (void)release_number;
    (void)manufacturer_string;
    (void)product_string;
    (void)interface_number;
    (void)interface_class;
    (void)interface_subclass;
    (void)interface_protocol;
}

JNIEXPORT void JNICALL Java_org_libsdl_app_HIDDeviceManager_HIDDeviceOpenPending(
    JNIEnv* env, jobject thiz, jint device_id) {
    (void)env;
    (void)thiz;
    (void)device_id;
}

JNIEXPORT void JNICALL Java_org_libsdl_app_HIDDeviceManager_HIDDeviceOpenResult(
    JNIEnv* env, jobject thiz, jint device_id, jboolean opened) {
    (void)env;
    (void)thiz;
    (void)device_id;
    (void)opened;
}

JNIEXPORT void JNICALL Java_org_libsdl_app_HIDDeviceManager_HIDDeviceDisconnected(
    JNIEnv* env, jobject thiz, jint device_id) {
    (void)env;
    (void)thiz;
    (void)device_id;
}

JNIEXPORT void JNICALL Java_org_libsdl_app_HIDDeviceManager_HIDDeviceInputReport(
    JNIEnv* env, jobject thiz, jint device_id, jbyteArray report) {
    (void)env;
    (void)thiz;
    (void)device_id;
    (void)report;
}

JNIEXPORT void JNICALL Java_org_libsdl_app_HIDDeviceManager_HIDDeviceFeatureReport(
    JNIEnv* env, jobject thiz, jint device_id, jbyteArray report) {
    (void)env;
    (void)thiz;
    (void)device_id;
    (void)report;
}
