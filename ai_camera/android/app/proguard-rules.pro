# v10 ML Kit: google_mlkit_text_recognition compiles against the Chinese /
# Devanagari / Japanese / Korean recognizers (compileOnly) but the app only
# ships Latin. These classes are never loaded; tell R8 not to fail on them.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
