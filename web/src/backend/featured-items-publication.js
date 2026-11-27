// Published merchant content is a single Stores snapshot, separate from editable drafts.
'use strict';
const crypto = require('node:crypto');

const RELEASE_FIELD = 'FeaturedItemsRelease';
const TAKEOVER_FIELD = 'FeaturedItemsTakenOver';
const own = (value, key) => Object.hasOwn(value || {}, key);
const plain = value => value && typeof value === 'object' && !Array.isArray(value);
const identity = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,200}$/.test(value);
const uploadPath = value => typeof value === 'string' && /^\/assets\/uploads\/[A-Za-z0-9][A-Za-z0-9._-]{0,160}\.(?:jpg|png|webp|gif)$/.test(value);
const fail = message => { throw Error('Invalid featured-items publication: ' + message); };

function isoDate(value, label) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)
    || !Number.isFinite(Date.parse(value)) || new Date(value).toISOString() !== value) fail(label);
  return value;
}

function title(value, label, { optional = false } = {}) {
  if (optional && value == null) return '';
  if (typeof value !== 'string' || !optional && !value.trim() || value.trim().length > 200 || /[\u0000-\u001f\u007f]/.test(value)) fail(label);
  return value.trim();
}

function imageUrl(value, { allowRelativeUploads = false } = {}) {
  if (value === '' || value == null) return '';
  if (typeof value !== 'string' || value !== value.trim()) fail('image URL');
  if (allowRelativeUploads && uploadPath(value)) return value;
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || !url.hostname || url.username || url.password) fail('image URL');
    return url.href;
  } catch { return fail('image URL'); }
}

function validateItem(item, options) {
  if (!plain(item) || !identity(item.id) || !['dish', 'event'].includes(item.kind)) fail('item identity or kind');
  if (typeof item.sortOrder !== 'number' || !Number.isFinite(item.sortOrder)) fail('item sort order');
  // Copy only public fields. Owner, user IDs, editor notes and draft bodies never survive.
  return {
    id: item.id,
    kind: item.kind,
    titleZh: title(item.titleZh, 'Chinese title', { optional: true }),
    titleEn: title(item.titleEn, 'English title'),
    imageUrl: imageUrl(item.imageUrl, options),
    sortOrder: item.sortOrder,
    updatedAt: isoDate(item.updatedAt, 'item update time')
  };
}

function storeIdentity(store) {
  const fields = store?.fields;
  if (!plain(fields) || !identity(fields.MallPoiId) || !identity(fields.AmapPoiId)
    || store.id !== `amap-${fields.AmapPoiId}`) fail('stable store identity');
  return { storeId: store.id, mallPoiId: fields.MallPoiId, amapPoiId: fields.AmapPoiId };
}

function parseRelease(raw, store, options) {
  let release = raw;
  if (typeof raw === 'string') {
    if (!raw.trim()) fail('empty release');
    try { release = JSON.parse(raw); } catch { return fail('release JSON'); }
  }
  const expected = storeIdentity(store);
  if (!plain(release) || release.schemaVersion !== 1 || release.takenOver !== true
    || !Number.isSafeInteger(release.revision) || release.revision < 1 || !Array.isArray(release.items)) fail('release schema');
  for (const key of ['storeId', 'mallPoiId', 'amapPoiId']) if (release[key] !== expected[key]) fail('branch identity');
  const seen = new Set();
  const items = release.items.map(item => {
    const clean = validateItem(item, options);
    if (seen.has(clean.id)) fail('duplicate item ID');
    seen.add(clean.id);
    return clean;
  }).sort((a, b) => a.sortOrder - b.sortOrder || a.id.localeCompare(b.id, 'en'));
  return {
    schemaVersion: 1,
    revision: release.revision,
    ...expected,
    takenOver: true,
    publishedAt: isoDate(release.publishedAt, 'publication time'),
    items
  };
}

function applyToStore(store, raw, options) {
  const release = parseRelease(raw, store, options);
  const fields = { ...store.fields };
  delete fields[RELEASE_FIELD];
  // Explicit empty arrays represent withdrawal, including the last item.
  delete fields.FeaturedDishes;
  delete fields.StoreEvents;
  Object.assign(fields, {
    FeaturedItems: release.items,
    FeaturedItemsOrigin: 'merchant',
    FeaturedItemsRevision: release.revision,
    FeaturedItemsTakenOver: true,
    FeaturedItemsPublishedAt: release.publishedAt
  });
  return { ...store, fields };
}

function isDemo(row) {
  return row?.fields?.Isdemo === true || /^demo\b/i.test(String(row?.fields?.Name || ''));
}

function merge(catalogue, cloudRows, options) {
  if (!plain(catalogue) || !Array.isArray(catalogue.records) || !Array.isArray(cloudRows)) fail('catalogue');
  const cloudByIdentity = new Map();
  for (const row of cloudRows) {
    if (!row || !plain(row.fields) || isDemo(row)) continue;
    const key = JSON.stringify([row.fields.MallPoiId, row.fields.AmapPoiId]);
    const matches = cloudByIdentity.get(key) || [];
    matches.push(row);
    cloudByIdentity.set(key, matches);
  }
  const links = catalogue.softrLinks;
  if (links !== undefined && !Array.isArray(links)) fail('Softr links');
  const seen = new Set();
  const records = catalogue.records.map(store => {
    const expected = storeIdentity(store);
    const key = JSON.stringify([expected.mallPoiId, expected.amapPoiId]);
    if (seen.has(key)) fail('duplicate verified branch');
    seen.add(key);
    const matches = cloudByIdentity.get(key) || [];
    if (matches.length !== 1 || !identity(matches[0].id)) fail('non-unique Softr branch');
    const row = matches[0];
    if (links) {
      const mapped = links.filter(link => link?.storeId === store.id);
      if (mapped.length !== 1 || mapped[0].softrRecordId !== row.id
        || own(mapped[0], 'amapPoiId') && mapped[0].amapPoiId !== expected.amapPoiId) fail('Softr link identity');
    }
    const marker = row.fields[TAKEOVER_FIELD];
    if (marker !== undefined && marker !== null && typeof marker !== 'boolean') fail('takeover marker');
    const raw = row.fields[RELEASE_FIELD];
    const empty = raw === undefined || raw === null || typeof raw === 'string' && !raw.trim();
    if (marker === true) return applyToStore(store, raw, options);
    // Newly added fields are empty on every legacy record. The checkbox records
    // a durable takeover and is PATCHed atomically with the publication itself.
    if (!empty) fail('release exists without takeover marker');
    if (store.fields.FeaturedItemsTakenOver === true) fail('missing release for managed branch');
    const fields = { ...store.fields };
    delete fields[RELEASE_FIELD];
    return { ...store, fields };
  });
  // Retrieval timestamps do not create content versions. Hash only actual catalogue data.
  const catalogueVersion = crypto.createHash('sha256').update(JSON.stringify({ mallId: catalogue.mallId, records })).digest('hex');
  return { ...catalogue, source: `${catalogue.source || 'catalogue'}+merchant-published`, records, catalogueVersion };
}

function publicFields(record, { curated, allowRelativeUploads = false } = {}) {
  const fields = record?.fields || {};
  if (fields.FeaturedItemsTakenOver !== true) {
    // Existing curated content remains governed by its existing evidence contract.
    return curated === undefined ? {} : { FeaturedDishes: structuredClone(curated) };
  }
  const release = parseRelease({
    schemaVersion: 1,
    revision: fields.FeaturedItemsRevision,
    ...storeIdentity(record),
    takenOver: true,
    publishedAt: fields.FeaturedItemsPublishedAt,
    items: fields.FeaturedItems
  }, record, { allowRelativeUploads });
  const group = kind => ({
    origin: 'merchant',
    revision: release.revision,
    publishedAt: release.publishedAt,
    items: release.items.filter(item => item.kind === kind).map(item => ({
      id: item.id, zh: item.titleZh || item.titleEn, en: item.titleEn, imageUrl: item.imageUrl,
      sortOrder: item.sortOrder, updatedAt: item.updatedAt
    }))
  });
  return {
    FeaturedItems: release.items,
    FeaturedItemsOrigin: 'merchant',
    FeaturedItemsRevision: release.revision,
    FeaturedItemsTakenOver: true,
    FeaturedItemsPublishedAt: release.publishedAt,
    FeaturedDishes: group('dish'),
    StoreEvents: group('event')
  };
}

function preserveTakeover(previous, next, options) {
  if (!previous) return;
  const nextById = new Map(next.records.map(record => [record.id, record]));
  for (const record of previous.records) {
    if (record.fields?.FeaturedItemsTakenOver !== true) continue;
    const current = nextById.get(record.id);
    if (!current || current.fields?.FeaturedItemsTakenOver !== true) fail('managed branch regressed to curated content');
    if (current.fields.FeaturedItemsRevision < record.fields.FeaturedItemsRevision) fail('publication revision regressed');
    if (current.fields.FeaturedItemsRevision === record.fields.FeaturedItemsRevision
      && JSON.stringify(publicFields(current, options)) !== JSON.stringify(publicFields(record, options))) fail('publication changed without a new revision');
  }
}

function createSource({ loadBase, loadCloud, now = Date.now, ttlMs = 60000, allowRelativeUploads = false }) {
  if (typeof loadBase !== 'function' || typeof loadCloud !== 'function') throw Error('Catalogue readers are required.');
  if (!Number.isFinite(ttlMs) || ttlMs < 0) throw Error('Invalid catalogue cache TTL.');
  let verified = null, cached = null, loadedAt = -Infinity, pending = null, generation = 0;
  async function load() {
    if (cached && now() - loadedAt < ttlMs) return cached;
    if (pending) return pending;
    const startedGeneration = generation;
    const request = Promise.resolve().then(async () => {
      try {
        const [base, cloud] = await Promise.all([loadBase(), loadCloud()]);
        const merged = merge(base, cloud, { allowRelativeUploads });
        preserveTakeover(verified, merged, { allowRelativeUploads });
        if (startedGeneration !== generation) return load();
        const value = { ...merged, stale: false, merchantContentVerifiedAt: new Date(now()).toISOString() };
        verified = value;
        cached = value;
        loadedAt = now();
        return value;
      } catch (error) {
        if (startedGeneration !== generation) return load();
        if (!verified) throw error;
        // Keep the entire last verified version; never combine fresh and stale branches.
        cached = { ...verified, stale: true, merchantContentSyncError: { code: 'MERCHANT_CONTENT_SYNC_FAILED' } };
        loadedAt = now();
        return cached;
      }
    }).finally(() => { if (pending === request) pending = null; });
    pending = request;
    return request;
  }
  function invalidate() {
    generation += 1;
    loadedAt = -Infinity;
    pending = null;
  }
  return { load, invalidate };
}

module.exports = { RELEASE_FIELD, TAKEOVER_FIELD, validateItem, parseRelease, applyToStore, merge, publicFields, createSource };
