/** Preserve artifact downloads separately from the release page in feed rows. */
export function toUpdateFeedEntry(row: {
  version: string;
  build: number;
  url: string | null;
  data: string;
}): Record<string, unknown> {
  const entry = JSON.parse(row.data) as Record<string, unknown>;
  entry.version = row.version;
  entry.build = row.build;
  if (row.url) {
    entry.download_url ||= row.url;
    entry.url ||= row.url;
  }
  return entry;
}
