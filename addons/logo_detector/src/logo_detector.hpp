#ifndef LOGO_DETECTOR_H
#define LOGO_DETECTOR_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <onnxruntime_cxx_api.h>
#include <memory>
#include <string>
#include <vector>

namespace godot {

class LogoDetector : public RefCounted {
    GDCLASS(LogoDetector, RefCounted)

public:
    struct Impl;

private:
    Impl *impl;

protected:
    static void _bind_methods();

public:
    LogoDetector();
    ~LogoDetector();

    // Load the YOLOv8-seg ONNX model used for logo/title region proposals.
    Error load_yolo_model(const String &p_model_path);

    // Load the RapidOCR text-detection ONNX model.
    Error load_ocr_det_model(const String &p_model_path);

    // Load the RapidOCR text-recognition ONNX model.
    Error load_ocr_rec_model(const String &p_model_path);

    // Load the RapidOCR text-classifier ONNX model (0°/180° rotation).
    Error load_ocr_cls_model(const String &p_model_path);

    // Load the character dictionary used by the recognition model.
    Error load_ocr_charset(const String &p_charset_path);

    bool is_yolo_model_loaded() const;
    bool is_ocr_det_model_loaded() const;
    bool is_ocr_rec_model_loaded() const;
    bool is_ocr_cls_model_loaded() const;

    // Run YOLO and return up to top_k candidate boxes after NMS.
    Array detect_candidates(
        const Ref<Image> &p_image,
        float p_conf_threshold = 0.15f,
        float p_nms_threshold = 0.45f,
        int p_top_k = 5
    );

    // Run OCR on the YOLO candidate crops and return recognized text for each region.
    Array ocr_full_image(const Ref<Image> &p_image);

    // Convenience: run YOLO, OCR, and return the candidate with the OCR word
    // that best matches the title. GDScript can still do its own scoring if
    // desired; this is a helper that mirrors the Python pipeline.
    Dictionary detect_title_box(
        const Ref<Image> &p_image,
        const String &p_title,
        float p_conf_threshold = 0.15f,
        float p_nms_threshold = 0.45f
    );
};

} // namespace godot

#endif // LOGO_DETECTOR_H
