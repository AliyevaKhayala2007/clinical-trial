-- =====================================================================
-- 22 - Cross-table business rules enforced in the database (hand-written)
-- =====================================================================
-- Rules that a single-table CHECK or FK cannot express. Most are DEFERRABLE INITIALLY
-- DEFERRED constraint triggers, so they are checked at COMMIT. An application can then
-- insert related rows in any order inside one transaction (e.g. kit dispensation before
-- the randomization row), and bulk loads in FK order still work.
-- Violations raise SQLSTATE 23514 (check_violation) with the rule id in the message.
--
--   BR01  serious_adverse_event only for an adverse_event with is_serious = true
--   BR02  subject_visit.visit_definition belongs to the subject's study
--   BR03  informed_consent.protocol_version belongs to the subject's study
--   BR04  eligibility_assessment.criterion belongs to the subject's study
--   BR05  visit_definition.study_epoch belongs to the protocol version's study
--   BR06  randomization_list_entry.study_arm belongs to the scheme's study
--   BR07  investigational_product.study_arm belongs to the product's study
--   BR08  subject_randomization uses a list entry of the subject's study, and marks it used
--   BR09  dispensed kit matches the subject's study and randomized arm
--   BR10  protocol_amendment links two versions of the same study
--   BR11  subject_stratum level belongs to the randomization's scheme
--
-- The validation script (scripts/validate.py) re-checks the same rules on loaded data.

CREATE SCHEMA IF NOT EXISTS rules;
COMMENT ON SCHEMA rules IS 'Cross-table business-rule trigger functions';

CREATE OR REPLACE FUNCTION rules.fail(p_rule text, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% violated: %', p_rule, p_msg USING ERRCODE = 'check_violation';
END $$;

-- Study of a protocol version / subject (NULL when not found; FKs cover existence).
CREATE OR REPLACE FUNCTION rules.pv_study(p uuid) RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT study_id FROM study.protocol_version WHERE protocol_version_id = p $$;
CREATE OR REPLACE FUNCTION rules.subject_study(p uuid) RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT study_id FROM subject.study_subject WHERE study_subject_id = p $$;

-- ---------- BR01 SAE requires a serious AE ----------
CREATE OR REPLACE FUNCTION rules.br01_sae_requires_serious() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_ae uuid := NEW.adverse_event_id;   -- same column name on both tables
BEGIN
    IF EXISTS (SELECT 1 FROM safety.serious_adverse_event s JOIN safety.adverse_event a USING (adverse_event_id)
                WHERE s.adverse_event_id = v_ae AND NOT s.is_deleted AND NOT a.is_serious) THEN
        PERFORM rules.fail('BR01', format('adverse_event %s has SAE details but is_serious = false', v_ae));
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER br01_sae_requires_serious AFTER INSERT OR UPDATE ON safety.serious_adverse_event
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION rules.br01_sae_requires_serious();
CREATE CONSTRAINT TRIGGER br01_sae_requires_serious AFTER UPDATE OF is_serious ON safety.adverse_event
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION rules.br01_sae_requires_serious();

-- ---------- BR02 visit definition from the subject's study ----------
CREATE OR REPLACE FUNCTION rules.br02_visit_study() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.visit_definition_id IS NOT NULL AND
       (SELECT rules.pv_study(protocol_version_id) FROM study.visit_definition
         WHERE visit_definition_id = NEW.visit_definition_id) IS DISTINCT FROM rules.subject_study(NEW.study_subject_id) THEN
        PERFORM rules.fail('BR02', format('subject_visit %s uses a visit definition of another study', NEW.subject_visit_id));
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER br02_visit_study AFTER INSERT OR UPDATE OF visit_definition_id, study_subject_id
    ON subject.subject_visit DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION rules.br02_visit_study();

-- ---------- BR03 consent on a protocol version of the subject's study ----------
CREATE OR REPLACE FUNCTION rules.br03_consent_study() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF rules.pv_study(NEW.protocol_version_id) IS DISTINCT FROM rules.subject_study(NEW.study_subject_id) THEN
        PERFORM rules.fail('BR03', format('informed_consent %s is on a protocol version of another study', NEW.informed_consent_id));
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER br03_consent_study AFTER INSERT OR UPDATE OF protocol_version_id, study_subject_id
    ON subject.informed_consent DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION rules.br03_consent_study();

-- ---------- BR04 eligibility criterion of the subject's study ----------
CREATE OR REPLACE FUNCTION rules.br04_eligibility_study() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT rules.pv_study(protocol_version_id) FROM study.eligibility_criterion
         WHERE eligibility_criterion_id = NEW.eligibility_criterion_id) IS DISTINCT FROM rules.subject_study(NEW.study_subject_id) THEN
        PERFORM rules.fail('BR04', format('eligibility_assessment %s uses a criterion of another study', NEW.eligibility_assessment_id));
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER br04_eligibility_study AFTER INSERT OR UPDATE OF eligibility_criterion_id, study_subject_id
    ON subject.eligibility_assessment DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION rules.br04_eligibility_study();

-- ---------- BR05 visit epoch of the protocol version's study ----------
CREATE OR REPLACE FUNCTION rules.br05_visit_epoch_study() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT study_id FROM study.study_epoch WHERE study_epoch_id = NEW.study_epoch_id)
       IS DISTINCT FROM rules.pv_study(NEW.protocol_version_id) THEN
        PERFORM rules.fail('BR05', format('visit_definition %s uses an epoch of another study', NEW.visit_definition_id));
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER br05_visit_epoch_study AFTER INSERT OR UPDATE OF study_epoch_id, protocol_version_id
    ON study.visit_definition DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION rules.br05_visit_epoch_study();

-- ---------- BR06 randomization list arm of the scheme's study ----------
CREATE OR REPLACE FUNCTION rules.br06_list_arm_study() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
    IF (SELECT study_id FROM study.study_arm WHERE study_arm_id = NEW.study_arm_id) IS DISTINCT FROM
       (SELECT study_id FROM subject.randomization_scheme WHERE randomization_scheme_id = NEW.randomization_scheme_id) THEN
        PERFORM rules.fail('BR06', format('randomization_list_entry %s uses an arm of another study', NEW.randomization_list_entry_id));
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER br06_list_arm_study AFTER INSERT OR UPDATE OF study_arm_id, randomization_scheme_id
    ON subject.randomization_list_entry DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION rules.br06_list_arm_study();

-- ---------- BR07 product arm of the product's study ----------
CREATE OR REPLACE FUNCTION rules.br07_product_arm_study() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
    IF NEW.study_arm_id IS NOT NULL AND
       (SELECT study_id FROM study.study_arm WHERE study_arm_id = NEW.study_arm_id) IS DISTINCT FROM NEW.study_id THEN
        PERFORM rules.fail('BR07', format('investigational_product %s uses an arm of another study', NEW.investigational_product_id));
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER br07_product_arm_study AFTER INSERT OR UPDATE OF study_arm_id, study_id
    ON supply.investigational_product DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION rules.br07_product_arm_study();

-- ---------- BR08 randomization: same study, consume the list entry ----------
-- SECURITY DEFINER: blinded roles may randomize but cannot read the list entry.
CREATE OR REPLACE FUNCTION rules.br08_randomization() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_scheme_study uuid;
BEGIN
    SELECT s.study_id INTO v_scheme_study
      FROM subject.randomization_list_entry e JOIN subject.randomization_scheme s USING (randomization_scheme_id)
     WHERE e.randomization_list_entry_id = NEW.randomization_list_entry_id;
    IF v_scheme_study IS DISTINCT FROM rules.subject_study(NEW.study_subject_id) THEN
        PERFORM rules.fail('BR08', format('subject_randomization %s uses a list entry of another study', NEW.subject_randomization_id));
    END IF;
    UPDATE subject.randomization_list_entry SET is_used = true
     WHERE randomization_list_entry_id = NEW.randomization_list_entry_id AND NOT is_used;
    RETURN NULL;
END $$;
CREATE TRIGGER br08_randomization AFTER INSERT OR UPDATE OF randomization_list_entry_id, study_subject_id
    ON subject.subject_randomization FOR EACH ROW EXECUTE FUNCTION rules.br08_randomization();

-- ---------- BR09 dispensed kit fits the subject ----------
CREATE OR REPLACE FUNCTION rules.br09_dispensation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    v_kit_study uuid;
    v_kit_arm   uuid;
    v_subj_arm  uuid;
BEGIN
    SELECT p.study_id, p.study_arm_id INTO v_kit_study, v_kit_arm
      FROM supply.kit k JOIN supply.product_lot l USING (product_lot_id)
      JOIN supply.investigational_product p USING (investigational_product_id)
     WHERE k.kit_id = NEW.kit_id;
    IF v_kit_study IS DISTINCT FROM rules.subject_study(NEW.study_subject_id) THEN
        PERFORM rules.fail('BR09', format('dispensation %s: kit belongs to another study', NEW.dispensation_id));
    END IF;
    SELECT e.study_arm_id INTO v_subj_arm
      FROM subject.subject_randomization r JOIN subject.randomization_list_entry e USING (randomization_list_entry_id)
     WHERE r.study_subject_id = NEW.study_subject_id AND NOT r.is_deleted;
    -- Arm-specific kits (study_arm_id set) may only go to subjects randomized to that arm.
    IF v_kit_arm IS NOT NULL AND v_kit_arm IS DISTINCT FROM v_subj_arm THEN
        PERFORM rules.fail('BR09', format('dispensation %s: kit arm does not match the subject''s randomized arm', NEW.dispensation_id));
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER br09_dispensation AFTER INSERT OR UPDATE OF kit_id, study_subject_id
    ON supply.dispensation DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION rules.br09_dispensation();

-- ---------- BR10 amendment within one study ----------
CREATE OR REPLACE FUNCTION rules.br10_amendment_study() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF rules.pv_study(NEW.from_protocol_version_id) IS DISTINCT FROM rules.pv_study(NEW.to_protocol_version_id) THEN
        PERFORM rules.fail('BR10', format('protocol_amendment %s links versions of different studies', NEW.protocol_amendment_id));
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER br10_amendment_study AFTER INSERT OR UPDATE OF from_protocol_version_id, to_protocol_version_id
    ON study.protocol_amendment DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION rules.br10_amendment_study();

-- ---------- BR11 stratum level of the randomization's scheme ----------
CREATE OR REPLACE FUNCTION rules.br11_stratum_scheme() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
    IF (SELECT f.randomization_scheme_id FROM subject.stratification_level l
          JOIN subject.stratification_factor f USING (stratification_factor_id)
         WHERE l.stratification_level_id = NEW.stratification_level_id) IS DISTINCT FROM
       (SELECT e.randomization_scheme_id FROM subject.subject_randomization r
          JOIN subject.randomization_list_entry e USING (randomization_list_entry_id)
         WHERE r.subject_randomization_id = NEW.subject_randomization_id) THEN
        PERFORM rules.fail('BR11', format('subject_stratum %s uses a level of another scheme', NEW.subject_stratum_id));
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER br11_stratum_scheme AFTER INSERT OR UPDATE OF stratification_level_id, subject_randomization_id
    ON subject.subject_stratum DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION rules.br11_stratum_scheme();

GRANT USAGE ON SCHEMA rules TO ct_app, ct_unblinded;
