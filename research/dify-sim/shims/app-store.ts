export const useStore = (selector: (s: any) => any) => selector({ appDetail: { mode: 'workflow' } })
