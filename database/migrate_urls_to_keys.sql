-- ─────────────────────────────────────────────────────────────
-- تحويل الروابط القديمة لمفاتيح:
--   http://localhost:4000/uploads/findings/x.png  →  findings/x.png
-- بيلمس بس الروابط المحلية (localhost / 127.0.0.1 / IP محلي).
-- الروابط الخارجية (https://...) ما بتتغير.
-- ملاحظة: الباك الجديد بيفهم الروابط القديمة كمان، فهاد تنظيف مش ضروري فوراً.
-- ─────────────────────────────────────────────────────────────

-- 1) شوفي قديش سطر رح يتغير (قبل ما تعدلي إشي)
WITH p AS (SELECT '^https?://(localhost|127\.0\.0\.1|[0-9]{1,3}(\.[0-9]{1,3}){3})(:[0-9]+)?/uploads/' AS re)
SELECT 'cases.cover_image_url' AS col, count(*) FROM cases, p WHERE cover_image_url ~* p.re
UNION ALL SELECT 'persons.photo_url',               count(*) FROM persons, p        WHERE photo_url ~* p.re
UNION ALL SELECT 'evidence_items.file_url',         count(*) FROM evidence_items, p WHERE file_url ~* p.re
UNION ALL SELECT 'evidence_items.thumbnail_url',    count(*) FROM evidence_items, p WHERE thumbnail_url ~* p.re
UNION ALL SELECT 'crime_scenes.image_url',          count(*) FROM crime_scenes, p   WHERE image_url ~* p.re
UNION ALL SELECT 'social_posts.image_url',          count(*) FROM social_posts, p   WHERE image_url ~* p.re
UNION ALL SELECT 'image_regions.enhanced_image_url',count(*) FROM image_regions, p  WHERE enhanced_image_url ~* p.re
UNION ALL SELECT 'lab_comparisons.a_crop_url',      count(*) FROM lab_comparisons, p WHERE a_crop_url ~* p.re
UNION ALL SELECT 'lab_comparisons.b_crop_url',      count(*) FROM lab_comparisons, p WHERE b_crop_url ~* p.re
UNION ALL SELECT 'findings.crop_url',               count(*) FROM findings, p       WHERE crop_url ~* p.re;


-- 2) التحويل نفسه (كله مع بعض أو ولا إشي)
BEGIN;

CREATE TEMP TABLE _re AS
SELECT '^https?://(localhost|127\.0\.0\.1|[0-9]{1,3}(\.[0-9]{1,3}){3})(:[0-9]+)?/uploads/'::text AS re;

UPDATE cases           SET cover_image_url    = regexp_replace(cover_image_url,    (SELECT re FROM _re), '', 'i') WHERE cover_image_url    ~* (SELECT re FROM _re);
UPDATE persons         SET photo_url          = regexp_replace(photo_url,          (SELECT re FROM _re), '', 'i') WHERE photo_url          ~* (SELECT re FROM _re);
UPDATE evidence_items  SET file_url           = regexp_replace(file_url,           (SELECT re FROM _re), '', 'i') WHERE file_url           ~* (SELECT re FROM _re);
UPDATE evidence_items  SET thumbnail_url      = regexp_replace(thumbnail_url,      (SELECT re FROM _re), '', 'i') WHERE thumbnail_url      ~* (SELECT re FROM _re);
UPDATE crime_scenes    SET image_url          = regexp_replace(image_url,          (SELECT re FROM _re), '', 'i') WHERE image_url          ~* (SELECT re FROM _re);
UPDATE social_posts    SET image_url          = regexp_replace(image_url,          (SELECT re FROM _re), '', 'i') WHERE image_url          ~* (SELECT re FROM _re);
UPDATE image_regions   SET enhanced_image_url = regexp_replace(enhanced_image_url, (SELECT re FROM _re), '', 'i') WHERE enhanced_image_url ~* (SELECT re FROM _re);
UPDATE lab_comparisons SET a_crop_url         = regexp_replace(a_crop_url,         (SELECT re FROM _re), '', 'i') WHERE a_crop_url         ~* (SELECT re FROM _re);
UPDATE lab_comparisons SET b_crop_url         = regexp_replace(b_crop_url,         (SELECT re FROM _re), '', 'i') WHERE b_crop_url         ~* (SELECT re FROM _re);
UPDATE findings        SET crop_url           = regexp_replace(crop_url,           (SELECT re FROM _re), '', 'i') WHERE crop_url           ~* (SELECT re FROM _re);

DROP TABLE _re;
COMMIT;


-- 3) تأكيد: لازم يطلع مفاتيح زي test-usb/scene.png و findings/....png
SELECT 'scene' AS kind, image_url AS stored FROM crime_scenes
UNION ALL SELECT 'evidence', file_url FROM evidence_items WHERE file_url IS NOT NULL
ORDER BY 1 LIMIT 20;
