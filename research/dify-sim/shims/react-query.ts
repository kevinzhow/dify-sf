// useSuspenseQuery({ ...systemFeaturesQueryOptions(), select }) -> { data: select(systemFeatures) }
export const useSuspenseQuery = (opts: any) => ({ data: opts.select ? opts.select(opts.queryFn()) : opts.queryFn() })
