/**
 * Every map Forever draws, from its UiMap table, with its English name. The ids are the ones the
 * addon records with each item source (C_Map.GetBestMapForUnit), so a source line joins to its
 * map without a lookup, and the name is what an English client records for it, which is how an
 * upload from a client in another language is recognised. Regenerated from the game when a build
 * adds a map; the site keeps the composed art for each at public/maps/<id>.jpg.
 */
export type ZoneKind = 'world' | 'continent' | 'zone';

export interface Zone {
  /** UiMap id, the same number the addon reports. */
  id: number;
  slug: string;
  name: string;
  /** UiMap id of the continent (or world) this map sits on; 0 for the world map. */
  parent: number;
  kind: ZoneKind;
}

export const ZONES: Zone[] = [
  { id: 947, slug: 'azeroth', name: 'Azeroth', parent: 0, kind: 'world' },
  { id: 1411, slug: 'durotar', name: 'Durotar', parent: 1414, kind: 'zone' },
  { id: 1412, slug: 'mulgore', name: 'Mulgore', parent: 1414, kind: 'zone' },
  { id: 1413, slug: 'the-barrens', name: 'The Barrens', parent: 1414, kind: 'zone' },
  { id: 1414, slug: 'kalimdor', name: 'Kalimdor', parent: 947, kind: 'continent' },
  { id: 1415, slug: 'eastern-kingdoms', name: 'Eastern Kingdoms', parent: 947, kind: 'continent' },
  { id: 1416, slug: 'alterac-mountains', name: 'Alterac Mountains', parent: 1415, kind: 'zone' },
  { id: 1417, slug: 'arathi-highlands', name: 'Arathi Highlands', parent: 1415, kind: 'zone' },
  { id: 1418, slug: 'badlands', name: 'Badlands', parent: 1415, kind: 'zone' },
  { id: 1419, slug: 'blasted-lands', name: 'Blasted Lands', parent: 1415, kind: 'zone' },
  { id: 1420, slug: 'tirisfal-glades', name: 'Tirisfal Glades', parent: 1415, kind: 'zone' },
  { id: 1421, slug: 'silverpine-forest', name: 'Silverpine Forest', parent: 1415, kind: 'zone' },
  {
    id: 1422,
    slug: 'western-plaguelands',
    name: 'Western Plaguelands',
    parent: 1415,
    kind: 'zone',
  },
  {
    id: 1423,
    slug: 'eastern-plaguelands',
    name: 'Eastern Plaguelands',
    parent: 1415,
    kind: 'zone',
  },
  {
    id: 1424,
    slug: 'hillsbrad-foothills',
    name: 'Hillsbrad Foothills',
    parent: 1415,
    kind: 'zone',
  },
  { id: 1425, slug: 'the-hinterlands', name: 'The Hinterlands', parent: 1415, kind: 'zone' },
  { id: 1426, slug: 'dun-morogh', name: 'Dun Morogh', parent: 1415, kind: 'zone' },
  { id: 1427, slug: 'searing-gorge', name: 'Searing Gorge', parent: 1415, kind: 'zone' },
  { id: 1428, slug: 'burning-steppes', name: 'Burning Steppes', parent: 1415, kind: 'zone' },
  { id: 1429, slug: 'elwynn-forest', name: 'Elwynn Forest', parent: 1415, kind: 'zone' },
  { id: 1430, slug: 'deadwind-pass', name: 'Deadwind Pass', parent: 1415, kind: 'zone' },
  { id: 1431, slug: 'duskwood', name: 'Duskwood', parent: 1415, kind: 'zone' },
  { id: 1432, slug: 'loch-modan', name: 'Loch Modan', parent: 1415, kind: 'zone' },
  { id: 1433, slug: 'redridge-mountains', name: 'Redridge Mountains', parent: 1415, kind: 'zone' },
  { id: 1434, slug: 'stranglethorn-vale', name: 'Stranglethorn Vale', parent: 1415, kind: 'zone' },
  { id: 1435, slug: 'swamp-of-sorrows', name: 'Swamp of Sorrows', parent: 1415, kind: 'zone' },
  { id: 1436, slug: 'westfall', name: 'Westfall', parent: 1415, kind: 'zone' },
  { id: 1437, slug: 'wetlands', name: 'Wetlands', parent: 1415, kind: 'zone' },
  { id: 1438, slug: 'teldrassil', name: 'Teldrassil', parent: 1414, kind: 'zone' },
  { id: 1439, slug: 'darkshore', name: 'Darkshore', parent: 1414, kind: 'zone' },
  { id: 1440, slug: 'ashenvale', name: 'Ashenvale', parent: 1414, kind: 'zone' },
  { id: 1441, slug: 'thousand-needles', name: 'Thousand Needles', parent: 1414, kind: 'zone' },
  {
    id: 1442,
    slug: 'stonetalon-mountains',
    name: 'Stonetalon Mountains',
    parent: 1414,
    kind: 'zone',
  },
  { id: 1443, slug: 'desolace', name: 'Desolace', parent: 1414, kind: 'zone' },
  { id: 1444, slug: 'feralas', name: 'Feralas', parent: 1414, kind: 'zone' },
  { id: 1445, slug: 'dustwallow-marsh', name: 'Dustwallow Marsh', parent: 1414, kind: 'zone' },
  { id: 1446, slug: 'tanaris', name: 'Tanaris', parent: 1414, kind: 'zone' },
  { id: 1447, slug: 'azshara', name: 'Azshara', parent: 1414, kind: 'zone' },
  { id: 1448, slug: 'felwood', name: 'Felwood', parent: 1414, kind: 'zone' },
  { id: 1449, slug: 'ungoro-crater', name: "Un'Goro Crater", parent: 1414, kind: 'zone' },
  { id: 1450, slug: 'moonglade', name: 'Moonglade', parent: 1414, kind: 'zone' },
  { id: 1451, slug: 'silithus', name: 'Silithus', parent: 1414, kind: 'zone' },
  { id: 1452, slug: 'winterspring', name: 'Winterspring', parent: 1414, kind: 'zone' },
  { id: 1453, slug: 'stormwind-city', name: 'Stormwind City', parent: 1415, kind: 'zone' },
  { id: 1454, slug: 'orgrimmar', name: 'Orgrimmar', parent: 1414, kind: 'zone' },
  { id: 1455, slug: 'ironforge', name: 'Ironforge', parent: 1415, kind: 'zone' },
  { id: 1456, slug: 'thunder-bluff', name: 'Thunder Bluff', parent: 1414, kind: 'zone' },
  { id: 1457, slug: 'darnassus', name: 'Darnassus', parent: 1414, kind: 'zone' },
  { id: 1458, slug: 'undercity', name: 'Undercity', parent: 1415, kind: 'zone' },
  { id: 1459, slug: 'alterac-valley', name: 'Alterac Valley', parent: 947, kind: 'zone' },
  { id: 1460, slug: 'warsong-gulch', name: 'Warsong Gulch', parent: 947, kind: 'zone' },
  { id: 1461, slug: 'arathi-basin', name: 'Arathi Basin', parent: 947, kind: 'zone' },
  { id: 2482, slug: 'mount-hyjal', name: 'Mount Hyjal', parent: 1414, kind: 'zone' },
  { id: 2521, slug: 'zephras-isle', name: 'Zephras Isle', parent: 947, kind: 'zone' },
  { id: 2524, slug: 'darkspear-islands', name: 'Darkspear Islands', parent: 947, kind: 'zone' },
  { id: 2548, slug: 'riverglades', name: 'Riverglades', parent: 1415, kind: 'zone' },
  { id: 2652, slug: 'shendralas', name: "Shen'dralas", parent: 1414, kind: 'zone' },
];
