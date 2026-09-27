import { createFrontendModule } from '@backstage/frontend-plugin-api';
import { SignInPageOverride } from './SignInPage';

export const signInPageModule = createFrontendModule({
  pluginId: 'app',
  extensions: [SignInPageOverride],
});
