/*
 * Keccak 256
 *
 */

extern "C"
{
#include "sph/sph_shavite.h"
#include "sph/sph_simd.h"
#include "sph/sph_keccak.h"
}
#include "miner.h"


#include "cuda_helper.h"

static uint32_t *d_hash[MAX_GPUS];
static uint32_t *h_nounce[MAX_GPUS];

extern void keccak256_cpu_init(int thr_id, uint32_t threads);
extern void keccak256_setBlock_80(void *pdata,const void *ptarget);
extern void keccak256_cpu_hash_80(int thr_id, uint32_t threads, uint32_t startNounce, uint32_t *d_hash,uint32_t *h_nounce);

// CPU Hash
extern "C" void keccak256_hash(void *state, const void *input)
{
	sph_keccak_context ctx_keccak;

	uint32_t hash[16];

	sph_keccak256_init(&ctx_keccak);
	sph_keccak256 (&ctx_keccak, input, 80);
	sph_keccak256_close(&ctx_keccak, (void*) hash);

	memcpy(state, hash, 32);
}

static bool init[MAX_GPUS] = { false };

extern int scanhash_keccak256(int thr_id, uint32_t *pdata,
	uint32_t *ptarget, uint32_t max_nonce,
	uint32_t *hashes_done)
{
	const uint32_t first_nonce = pdata[19];
	uint32_t throughput = device_intensity(device_map[thr_id], __func__, 1U << 21); // 256*256*8*4
	throughput = min(throughput, (max_nonce - first_nonce));

	if (opt_benchmark)
		ptarget[7] = 0x0002;

	if (!init[thr_id]) {
		if (thr_id%opt_n_gputhreads == 0)
		{
			CUDA_SAFE_CALL(cudaSetDevice(device_map[thr_id]));
			cudaDeviceReset();
			cudaSetDeviceFlags(cudaDeviceBlockingSync);
			cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
		}
		else
		{
			while (!init[thr_id - thr_id%opt_n_gputhreads])
			{
			}
			CUDA_SAFE_CALL(cudaSetDevice(device_map[thr_id]));
		}

		CUDA_SAFE_CALL(cudaMalloc(&d_hash[thr_id], 16 * sizeof(uint32_t) * throughput));
		keccak256_cpu_init(thr_id, (int)throughput);
		CUDA_SAFE_CALL(cudaMallocHost(&h_nounce[thr_id], 4 * sizeof(uint32_t)));
		init[thr_id] = true;
	}

	uint32_t endiandata[20];
	for (int k=0; k < 20; k++) {
		be32enc(&endiandata[k], pdata[k]);
	}

	keccak256_setBlock_80((void*)endiandata, ptarget);

	do {

		keccak256_cpu_hash_80(thr_id, (int) throughput, pdata[19], d_hash[thr_id], h_nounce[thr_id]);
		if (h_nounce[thr_id][0] != UINT32_MAX)
		{
			uint32_t Htarg = ptarget[7];
			uint32_t vhash64[8];
			be32enc(&endiandata[19], h_nounce[thr_id][0]);
			keccak256_hash(vhash64, endiandata);

			if (vhash64[7] <= Htarg && fulltest(vhash64, ptarget))
			{
				int res = 1;
				// check if there was some other ones...
				*hashes_done = pdata[19] - first_nonce + throughput;
				if (h_nounce[thr_id][1] != 0xffffffff)
				{
					be32enc(&endiandata[19], h_nounce[thr_id][1]);
					keccak256_hash(vhash64, endiandata);

					if (vhash64[7] <= Htarg && fulltest(vhash64, ptarget))
					{
						pdata[21] = h_nounce[thr_id][1];
						res++;
						if (opt_benchmark)
							applog(LOG_INFO, "GPU #%d Found second nounce %08x", device_map[thr_id], h_nounce[thr_id][1]);
					}
					else
					{
						if (vhash64[7] != Htarg)
						{
							applog(LOG_WARNING, "GPU #%d: result for %08x does not validate on CPU!", device_map[thr_id], h_nounce[thr_id][1]);
						}
					}
				}
				pdata[19] = h_nounce[thr_id][0];
				if (opt_benchmark)
					applog(LOG_INFO, "GPU #%d Found nounce %08x", device_map[thr_id], h_nounce[thr_id][0]);
				MyStreamSynchronize(NULL, NULL, device_map[thr_id]);
				return res;
			}
			else
			{
				if (vhash64[7] != Htarg)
				{
					applog(LOG_WARNING, "GPU #%d: result for %08x does not validate on CPU!", device_map[thr_id], h_nounce[thr_id][0]);
				}
			}
		}

		pdata[19] += throughput; CUDA_SAFE_CALL(cudaGetLastError());
	} while (!work_restart[thr_id].restart && ((uint64_t)max_nonce > ((uint64_t)(pdata[19]) + (uint64_t)throughput)));

	*hashes_done = pdata[19] - first_nonce;
	MyStreamSynchronize(NULL, NULL, device_map[thr_id]);
	return 0;
}
