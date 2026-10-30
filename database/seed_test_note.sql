-- =====================================================================
--  QADIYA – إضافة "ورقة بخط اليد" على طاولة غرفة الجلوس (عارض الورقة + تضوية السطور)
--  بتنضاف على القضية التجريبية TEST-USB-01 (لازم seed_test_usb.sql يكون منفّذ قبل).
--
--  الفكرة (نفس فكرة الفلاشة):
--    - clue كوده بيبلش بـ DOC-  = شي بالمسرح بيفتح كـ "ورقة"
--    - صفحات الورقة = evidence_items مربوطة فيه بـ collected_location = الكود
--      (الترتيب حسب display_order، وهيك الكتاب BOOK- بعدين بنفس الطريقة)
--    - السطر المهم = منطقة نوعها text على الصفحة، معها revealed_text و clue
--
--  للحذف (الإضافات هاي بس):
--    DELETE FROM image_regions WHERE clue_id IN (SELECT clue_id FROM clues WHERE code IN ('DOC-NOTE-01','CL-SPARE-KEY'));
--    DELETE FROM evidence_items WHERE collected_location = 'DOC-NOTE-01';
--    DELETE FROM clues WHERE code IN ('DOC-NOTE-01','CL-SPARE-KEY');
-- =====================================================================

BEGIN;

-- 1) الـclues
INSERT INTO clues (case_id, code, title, description) VALUES
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 'DOC-NOTE-01', 'Handwritten note', 'Lined note on the coffee table'),
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 'CL-SPARE-KEY', 'Spare key location', 'Line in the handwritten note: the spare key is under the plant by the door.');

-- 2) صفحة الورقة (ظاهرة من الأول، مش مخفية)
INSERT INTO evidence_items (case_id, origin_type, media_type, title, description, source,
                            file_url, collected_location, is_hidden_initially, display_order)
VALUES ((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'), 'police', 'document',
        'Handwritten note - page 1', 'Lined paper, blue ink.', 'Coffee table',
        'test-usb/note_page_1.png', 'DOC-NOTE-01', FALSE, 1);

-- 3) المناطق
INSERT INTO image_regions (case_id, scene_id, evidence_id, region_type, x, y, w, h,
                           observed_details, revealed_text, clue_id, min_overlap)
VALUES
-- الورقة على الطاولة (ظاهرة، بتضوي بالـHover) ← بتفتح عارض الورقة
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 (SELECT scene_id FROM crime_scenes s JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01'),
 NULL, 'area', 0.32459, 0.70258, 0.16782, 0.16759,
 'Handwritten Note. A sheet of lined paper lies flat on the table, written in blue ink.',
 NULL,
 (SELECT clue_id FROM clues cl JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND cl.code = 'DOC-NOTE-01'),
 0.30),
-- السطر المهم جوا الصفحة
((SELECT case_id FROM cases WHERE case_number = 'TEST-USB-01'),
 NULL,
 (SELECT evidence_id FROM evidence_items e JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND e.collected_location = 'DOC-NOTE-01' AND e.display_order = 1),
 'text', 0.14100, 0.56511, 0.84156, 0.06056,
 'A handwritten line in the middle of the page.',
 'Spare key: under the plant by the door',
 (SELECT clue_id FROM clues cl JOIN cases c USING (case_id) WHERE c.case_number = 'TEST-USB-01' AND cl.code = 'CL-SPARE-KEY'),
 0.30);

COMMIT;

-- تأكيد
SELECT r.region_id, r.region_type, cl.code AS clue, r.revealed_text,
       CASE WHEN r.scene_id IS NOT NULL THEN 'scene' ELSE 'page' END AS on_what
FROM image_regions r
JOIN cases c USING (case_id)
LEFT JOIN clues cl ON cl.clue_id = r.clue_id
WHERE c.case_number = 'TEST-USB-01' AND cl.code IN ('DOC-NOTE-01', 'CL-SPARE-KEY');
