import { registerPlugin } from '@capacitor/core';
import type { LiveStreamPlayerPlugin } from './definitions';

const LiveStreamPlayer = registerPlugin<LiveStreamPlayerPlugin>(
  'LiveStreamPlayer',
  {
    web: () => import('./web').then(m => new m.LiveStreamPlayerWeb()),
  },
);

export * from './definitions';
export { LiveStreamPlayer };
