/**
 * @NApiVersion 2.1
 * @NScriptType Restlet
 *
 * SuiGit capture endpoint. POST: accept a batch of files just pushed from
 * VS Code and write a customrecord_suigit_version row per file IF the content
 * hash differs from the latest stored version for that path. Idempotent for
 * unchanged files. GET: read the latest version for a given path.
 */
define(['N/record', 'N/search', 'N/file', 'N/log'],
    (record, search, file, log) => {

        const REC    = 'customrecord_suigit_version';
        const F_FID  = 'custrecord_suigit_fileid';
        const F_PATH = 'custrecord_suigit_filepath';
        const F_NAME = 'custrecord_suigit_filename';
        const F_BODY = 'custrecord_suigit_content';
        const F_HASH = 'custrecord_suigit_hash';
        const F_SIZE = 'custrecord_suigit_size';
        const F_WHEN = 'custrecord_suigit_captured';

        const post = (body) => {
            const payload = (typeof body === 'string') ? JSON.parse(body) : body;
            if (!payload || !Array.isArray(payload.files)) {
                return { ok: false, error: 'payload.files[] required' };
            }
            const out = { created: [], unchanged: [], failed: [] };

            payload.files.forEach((f) => {
                try {
                    if (!f.path) {
                        out.failed.push({ path: null, reason: 'missing path' });
                        return;
                    }
                    const path = trim(f.path, 300);
                    const content = (typeof f.content === 'string') ? f.content : '';
                    const h = f.hash || hashOf(content);

                    const latest = getLatestForPath(path);
                    if (latest && latest.hash === h) {
                        out.unchanged.push(path);
                        return;
                    }

                    const fileId = resolveFileId(path);

                    const rec = record.create({ type: REC });
                    rec.setValue({ fieldId: 'name',  value: trim(basename(path) + ' @ ' + new Date().toISOString(), 100) });
                    rec.setValue({ fieldId: F_FID,   value: fileId || 0 });
                    rec.setValue({ fieldId: F_PATH,  value: path });
                    rec.setValue({ fieldId: F_NAME,  value: basename(path) });
                    rec.setValue({ fieldId: F_BODY,  value: content });
                    rec.setValue({ fieldId: F_HASH,  value: h });
                    rec.setValue({ fieldId: F_SIZE,  value: content.length });
                    rec.setValue({ fieldId: F_WHEN,  value: new Date() });
                    const vid = rec.save({ ignoreMandatoryFields: true });
                    out.created.push({ path: path, versionId: vid, fileId: fileId });
                } catch (e) {
                    log.error('SuiGit RESTlet file failed', { path: f.path, error: e.message || String(e) });
                    out.failed.push({ path: f.path, reason: e.message || String(e) });
                }
            });

            log.audit('SuiGit RESTlet batch', {
                author:    payload.author || '',
                commit:    payload.commit || '',
                created:   out.created.length,
                unchanged: out.unchanged.length,
                failed:    out.failed.length
            });
            return Object.assign({ ok: true }, out);
        };

        const get = (params) => {
            if (params.path) {
                const v = getLatestForPath(params.path);
                return v ? { ok: true, version: v } : { ok: false, error: 'not found' };
            }
            return { ok: false, error: 'path param required' };
        };

        // ---------- helpers ----------

        const getLatestForPath = (path) => {
            let v = null;
            search.create({
                type: REC,
                filters: [[F_PATH, 'is', path]],
                columns: [
                    { name: F_HASH },
                    { name: F_WHEN, sort: search.Sort.DESC },
                    { name: 'internalid' }
                ]
            }).run().each(r => {
                v = { versionId: r.getValue('internalid'), hash: r.getValue(F_HASH) };
                return false;
            });
            return v;
        };

        const resolveFileId = (path) => {
            try {
                const f = file.load({ id: '/' + path });
                return +f.id;
            } catch (e) {
                log.audit('SuiGit RESTlet file not in cabinet yet', { path: path, reason: e.message || String(e) });
                return 0;
            }
        };

        const hashOf = (s) => {
            let h = 0x811c9dc5;
            for (let i = 0; i < s.length; i++) {
                h ^= s.charCodeAt(i);
                h = Math.imul(h, 0x01000193);
            }
            return (h >>> 0).toString(16) + ':' + s.length;
        };
        const trim = (s, n) => (s && s.length > n) ? s.substring(0, n) : s;
        const basename = (p) => { const i = p.lastIndexOf('/'); return i < 0 ? p : p.substring(i + 1); };

        return { post: post, get: get };
    });
