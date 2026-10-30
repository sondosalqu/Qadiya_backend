-- =====================================================================
--  QADIYA – بيانات تجريبية لميزة الفلاشة (Interactive Objects)
--  قضية تجريبية لحالها: TEST-USB-01 (draft، ما بتبين للاعبين)
--  كل البيانات وهمية. الروابط والإحداثيات مؤقتة وبتتعدل بعدين.
--
--  للحذف الكامل (بيحذف كل إشي تحت القضية):
--    DELETE FROM cases WHERE case_number = 'TEST-USB-01';
-- =====================================================================

BEGIN;

-- 1) أدمن تجريبي (إذا موجود ما بيتكرر)
--    تسجيل الدخول: qd_test_admin  /  Qadiya-Test-2026
INSERT INTO users (full_name, username, email, password_hash, role)
VALUES ('Test Admin', 'qd_test_admin', 'qd_test_admin@example.com', '$2a$10$YBjki5tB2PnxYaLKfYHnJ.e6o8bzigLK4zpo0iM0jS/uCr5tXektG', 'admin')
ON CONFLICT (username) DO NOTHING;

-- 2) القضية
INSERT INTO cases (case_number, title, short_description, case_type, priority,
                   incident_at, incident_location, summary_text, publish_status, created_by)
VALUES ('TEST-USB-01', 'Living Room (USB test)',
        'Test case for the interactive USB drive feature.',
        'theft', 'medium',
        '2026-03-12 23:30+03', 'Unit 4B, Al-Rimal Tower',
        'Test data only.', 'draft',
        (SELECT user_id FROM users WHERE username = 'qd_test_admin'));

-- 3) صورة مسرح الجريمة
INSERT INTO crime_scenes (case_id, title, description, image_url, image_width, image_height)
VALUES ((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
        'Living Room', 'Main crime scene photo: coffee table, sofa, open door to the hallway.',
        'test-usb/scene.png', 1448, 1086);

-- 4) الـclues
INSERT INTO clues (case_id, code, title, description) VALUES
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 'DEV-USB-01', 'USB Flash Drive', 'USB_DRIVE (E:)'),
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 'CL-CAM-BACKUP', 'Camera backup reference', 'Line in transfer_notes.pdf that mentions the camera backup.');

-- 5) ملفات الفلاشة: كلها مخفية، ومربوطة بالفلاشة عن طريق collected_location = code
INSERT INTO evidence_items (case_id, origin_type, media_type, title, description, source,
                            file_url, collected_at, collected_location, is_hidden_initially)
VALUES
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'), 'police', 'image',
 'IMG_2041.jpg', 'Photo stored on the USB drive.', 'USB_DRIVE (E:)',
 'test-usb/IMG_2041.jpg', '2026-03-12 23:41+03', 'DEV-USB-01', TRUE),
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'), 'police', 'document',
 'transfer_notes.pdf', 'Document stored on the USB drive.', 'USB_DRIVE (E:)',
 'test-usb/transfer_notes.png', '2026-03-11 18:05+03', 'DEV-USB-01', TRUE),
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'), 'police', 'video',
 'cam_backup.mp4', 'Video stored on the USB drive.', 'USB_DRIVE (E:)',
 'test-usb/cam_backup.mp4', '2026-03-12 22:58+03', 'DEV-USB-01', TRUE);

-- 6) المناطق (image_regions)
--    area   = غرض ظاهر (بيضوي بالـHover)
--    object = دليل مخفي (ما بيضوي)
--    text   = سطر نص جوا ملف
INSERT INTO image_regions (case_id, scene_id, evidence_id, region_type, x, y, w, h,
                           observed_details, revealed_text, clue_id, min_overlap)
VALUES
-- اللابتوب (ظاهر، بدون clue)
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 (SELECT scene_id FROM crime_scenes s JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01'),
 NULL, 'area', 0.79765, 0.49263, 0.20235, 0.12891,
 'Laptop. Closed on the right side of the table, partly covered by papers. A computer mouse rests on the lid.', NULL, NULL, 0.30),
-- الكاسة (ظاهر، بدون clue)
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 (SELECT scene_id FROM crime_scenes s JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01'),
 NULL, 'area', 0.18094, 0.42818, 0.12569, 0.15193,
 'Mug. White enamel, about half full. The coffee is cold; a dark ring has dried inside the rim.', NULL, NULL, 0.30),
-- الدفتر (ظاهر، بدون clue)
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 (SELECT scene_id FROM crime_scenes s JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01'),
 NULL, 'area', 0.0, 0.54788, 0.3384, 0.19797,
 'Leather Notebook. Tied shut with an elastic band. Corners worn; several pages sticking out.', NULL, NULL, 0.30),
-- المنفضة (ظاهر، بدون clue)
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 (SELECT scene_id FROM crime_scenes s JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01'),
 NULL, 'area', 0.37707, 0.44383, 0.19061, 0.10313,
 'Ashtray. Black marble, holding several cigarette butts of the same brand.', NULL, NULL, 0.30),
-- الفلاشة (مخفية، مربوطة بـDEV-USB-01)
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 (SELECT scene_id FROM crime_scenes s JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01'),
 NULL, 'object', 0.43646, 0.61510, 0.10221, 0.04236,
 'USB Flash Drive. Black drive lying on the coffee table, between the ashtray and the papers. No label.',
 NULL,
 (SELECT clue_id FROM clues cl JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND cl.code = 'DEV-USB-01'),
 0.30),
-- سطر الكاميرا جوا المستند (على الملف نفسه، مش على المشهد)
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 NULL,
 (SELECT evidence_id FROM evidence_items e JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND e.title = 'transfer_notes.pdf'),
 'text', 0.05000, 0.50000, 0.80000, 0.05000,
 'A typed line near the middle of the page.',
 'Camera backup is on the drive. Delete it after the transfer.',
 (SELECT clue_id FROM clues cl JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND cl.code = 'CL-CAM-BACKUP'),
 0.30);

-- 7) قواعد الكشف (unlock_rules)
INSERT INTO unlock_rules (case_id, trigger_type, trigger_clue_id, unlock_evidence_id, notify_message)
VALUES
-- فتح الفلاشة بيكشف الصورة
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'), 'clue_found',
 (SELECT clue_id FROM clues cl JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND cl.code = 'DEV-USB-01'),
 (SELECT evidence_id FROM evidence_items e JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND e.title = 'IMG_2041.jpg'),
 NULL),
-- فتح الفلاشة بيكشف المستند
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'), 'clue_found',
 (SELECT clue_id FROM clues cl JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND cl.code = 'DEV-USB-01'),
 (SELECT evidence_id FROM evidence_items e JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND e.title = 'transfer_notes.pdf'),
 NULL),
-- حفظ سطر الكاميرا من المستند بيكشف الفيديو
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'), 'clue_found',
 (SELECT clue_id FROM clues cl JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND cl.code = 'CL-CAM-BACKUP'),
 (SELECT evidence_id FROM evidence_items e JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND e.title = 'cam_backup.mp4'),
 'New file found on USB_DRIVE (E:)');

-- 8) "لاعب" للتجربة: الأدمن نفسه بوضع Preview
--    points_remaining بيتعبى لحاله من cases.initial_points (trigger)
INSERT INTO case_progress (case_id, user_id, assigned_by, status, is_admin_preview, started_at)
VALUES ((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
        (SELECT user_id FROM users WHERE username = 'qd_test_admin'),
        (SELECT user_id FROM users WHERE username = 'qd_test_admin'),
        'in_progress', TRUE, now());

COMMIT;

-- =====================================================================
--  تأكيد: شغّليها بعد الإدخال
-- =====================================================================
SELECT r.region_id, r.region_type, r.x, r.y, r.w, r.h,
       CASE WHEN r.scene_id IS NOT NULL THEN 'scene' ELSE 'file' END AS on_what,
       cl.code AS clue
FROM image_regions r
JOIN cases c USING (case_id)
LEFT JOIN clues cl ON cl.clue_id = r.clue_id
WHERE c.case_number = 'TEST-USB-01'
ORDER BY r.region_id;

SELECT ur.rule_id, cl.code AS when_found, e.title AS unlocks
FROM unlock_rules ur
JOIN clues cl ON cl.clue_id = ur.trigger_clue_id
JOIN evidence_items e ON e.evidence_id = ur.unlock_evidence_id
JOIN cases c ON c.case_id = ur.case_id
WHERE c.case_number = 'TEST-USB-01'
ORDER BY ur.rule_id;
