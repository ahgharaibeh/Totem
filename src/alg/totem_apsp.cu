/*
 * All pairs shortest path algorithm based on the Floyd-Warshall algorithm for
 * the CPU implementation.
 * According to [Harish07], running Dijkstra's algorithm for every vertex on the
 * graph, as compared to a parallel Floyd-Warshall algorithm, was both more
 * memory efficient (O(V) as compared to O(V^2)) and faster.
 *
 *  Created on: 2011-11-04
 *      Author: Greg Redekop
 */

// totem includes
#include "totem_alg.h"

// Externed function declarations for dijkstra kernel functions
__global__ void sssp_kernel(graph_t, bool*, weight_t*, weight_t*);
__global__ void sssp_final_kernel(graph_t, bool*, weight_t*, weight_t*,
                                      bool* has_true);


/**
 * Checks for input parameters and special cases. This is invoked at the
 * beginning of public interfaces (GPU and CPU)
 */
PRIVATE
error_t check_special_cases(graph_t* graph, weight_t **distances,
                            bool* finished) {

  *finished = true;
  if ((graph == NULL) || !graph->weighted || graph->vertex_count <= 0) {
    *distances = NULL;
    return FAILURE;
  }
  else if (graph->vertex_count == 1) {
    CALL_SAFE(totem_malloc(sizeof(weight_t), TOTEM_MEM_HOST_PINNED, 
                           (void**)distances));
    (*distances)[0] = 0;
    return SUCCESS;
  }

  vid_t v_count = graph->vertex_count;
  // Check whether the graph has vertices, but an empty edge set.
  if ((v_count > 0) && (graph->edge_count == 0)) {
    CALL_SAFE(totem_malloc(v_count * v_count * sizeof(weight_t), 
                           TOTEM_MEM_HOST_PINNED, (void**)distances));

    for (vid_t src = 0; src < v_count; src++) {
      // Initialize path lengths to WEIGHT_MAX.
      weight_t* base = &(*distances)[src * v_count];
      for (vid_t dest = 0; dest < v_count; dest++) {
        base[dest] = (weight_t)WEIGHT_MAX;
      }
      // 0 distance to oneself
      base[src] = 0;
    }
    return SUCCESS;
  }

  *finished = false;
  return SUCCESS;
}

/**
 * An initialization function for the GPU implementation of APSP. This function
 * allocates memory for use with Dijkstra's algorithm.
*/
PRIVATE
error_t initialize_gpu(graph_t* graph, vid_t distance_length,
                       graph_t** graph_d, weight_t** distances_d,
                       weight_t** new_distances_d, bool** changed_d,
                       bool** has_true_d) {
  totem_mem_t mem_type = TOTEM_MEM_DEVICE;

  // Initialize the graph
  CHK_SUCCESS(graph_initialize_device(graph, graph_d), err);

  // The distance array from the source vertex to every node in the graph.
  CHK_SUCCESS(totem_calloc(distance_length * sizeof(weight_t), mem_type,
                           (void**)distances_d), err_free_graph);
  
  // An array that contains the newly computed array of distances.
  CHK_SUCCESS(totem_calloc(distance_length * sizeof(weight_t), mem_type, 
                           (void**)new_distances_d), err_free_distances);
  // An entry in this array indicate whether the corresponding vertex should
  // try to compute new distances.
  CHK_SUCCESS(totem_calloc(distance_length * sizeof(bool), mem_type, 
                           (void **)changed_d), err_free_new_distances);
  // Initialize the flags that indicate whether the distances were updated
  CHK_SUCCESS(totem_calloc(sizeof(bool), mem_type, (void **)has_true_d),
              err_free_all);

  return SUCCESS;

  // error handlers
  err_free_all:
    totem_free(*changed_d, mem_type);
  err_free_new_distances:
    totem_free(*new_distances_d, mem_type);
  err_free_distances:
    totem_free(*distances_d, mem_type);
  err_free_graph:
    graph_finalize_device(*graph_d);
  err:
    return FAILURE;
}


/**
 * An initialization function for GPU implementations of APSP. This function
 * initializes state for running an iteration of Dijkstra's algorithm on a
 * source vertex.
*/
PRIVATE
error_t initialize_source_gpu(vid_t source_id, vid_t distance_length, 
                              bool* changed_d, bool* has_true_d,
                              weight_t* distances_d,
                              weight_t* new_distances_d) {
  // Set all distances to infinite.
  totem_memset(distances_d, WEIGHT_MAX, distance_length, TOTEM_MEM_DEVICE);
  totem_memset(new_distances_d, WEIGHT_MAX, distance_length, TOTEM_MEM_DEVICE);

  // Set the distance to the source to zero.
  CHK_CU_SUCCESS(cudaMemset(&(distances_d[source_id]), (weight_t)0,
                            sizeof(weight_t)), err);

  // Activate the source vertex to compute distances.
  CHK_CU_SUCCESS(cudaMemset(changed_d, false, distance_length * sizeof(bool)),
                 err);
  CHK_CU_SUCCESS(cudaMemset(&(changed_d[source_id]), true, sizeof(bool)), err);

  // Initialize the flags that indicate whether the distances were updated
  CHK_CU_SUCCESS(cudaMemset(has_true_d, false, sizeof(bool)), err);

  return SUCCESS;

  // error handlers
  err:
    return FAILURE;

  /* // Kernel configuration parameters. */
  /* dim3 block_count; */
  /* dim3 threads_per_block; */

  /* // Compute the number of blocks. */
  /* KERNEL_CONFIGURE(distance_length, block_count, threads_per_block); */

  /* // Set all distances to infinite. */
  /* memset_device<<<block_count, threads_per_block>>> */
  /*     (*distances_d, WEIGHT_MAX, distance_length); */
  /* memset_device<<<block_count, threads_per_block>>> */
  /*     (*new_distances_d, WEIGHT_MAX, distance_length); */

  /* // Set the distance to the source to zero. */
  /* CHK_CU_SUCCESS(cudaMemset(&((*distances_d)[source_id]), (weight_t)0, */
  /*                sizeof(weight_t)), err); */

  /* // Activate the source vertex to compute distances. */
  /* CHK_CU_SUCCESS(cudaMemset(&((*changed_d)[source_id]), true, sizeof(bool)), */
  /*                err); */

  /* // Initialize the flags that indicate whether the distances were updated */
  /* CHK_CU_SUCCESS(cudaMemset(*has_true_d, false, sizeof(bool)), err); */

  /* return SUCCESS; */

  /* // error handlers */
  /* err: */
  /*   return FAILURE; */
}


/**
 * A common finalize function for GPU implementations. It frees up the GPU
 * resources.
*/
PRIVATE
void finalize_gpu(graph_t* graph, graph_t* graph_d, weight_t* distances_d,
                  bool* changed_d, weight_t* new_distances_d,
                  bool* has_true_d) {
  // Release the allocated memory
  totem_mem_t mem_type = TOTEM_MEM_DEVICE;
  totem_free(distances_d, mem_type);
  totem_free(changed_d, mem_type);
  totem_free(new_distances_d, mem_type);
  totem_free(has_true_d, mem_type);
  graph_finalize_device(graph_d);
}


/**
 * All Pairs Shortest Path algorithm on the GPU.
 */
error_t apsp_gpu(graph_t* graph, weight_t** path_ret) {
  bool finished;
  error_t ret_val = check_special_cases(graph, path_ret, &finished);
  if (finished) return ret_val;

  // The distances array mimics a static array to avoid the overhead of
  // creating an array of pointers. Thus, accessing index [i][j] will be
  // done as distances[(i * vertex_count) + j]
  weight_t* distances = NULL;
  CALL_SAFE(totem_malloc(graph->vertex_count * graph->vertex_count * 
                         sizeof(weight_t), TOTEM_MEM_HOST_PINNED, 
                         (void**)&distances));

  // Allocate and initialize GPU state
  bool* changed_d;
  bool* has_true_d;
  graph_t* graph_d;
  weight_t* distances_d;
  weight_t* new_distances_d;
  CHK_SUCCESS(initialize_gpu(graph, graph->vertex_count, &graph_d, &distances_d,
                             &new_distances_d, &changed_d, &has_true_d), err);

  {
  dim3 block_count, threads_per_block;
  KERNEL_CONFIGURE(graph->vertex_count, block_count, threads_per_block);
  for (vid_t source_id = 0; source_id < graph->vertex_count; source_id++) {
    // Run SSSP for the selected vertex
    CHK_SUCCESS(initialize_source_gpu(source_id, graph->vertex_count,
                                      changed_d, has_true_d, distances_d,
                                      new_distances_d), err_free_all);
    bool has_true = true;
    while (has_true) {
      sssp_kernel<<<block_count, threads_per_block>>>
        (*graph_d, changed_d, distances_d, new_distances_d);
      CHK_CU_SUCCESS(cudaMemset(changed_d, false, graph->vertex_count *
                                sizeof(bool)), err_free_all);
      CHK_CU_SUCCESS(cudaMemset(has_true_d, false, sizeof(bool)), err_free_all);
      sssp_final_kernel<<<block_count, threads_per_block>>>
        (*graph_d, changed_d, distances_d, new_distances_d, has_true_d);
      CHK_CU_SUCCESS(cudaMemcpy(&has_true, has_true_d, sizeof(bool),
                                cudaMemcpyDeviceToHost), err_free_all);
    }
    // Copy the output shortest distances from the device mem to the host
    weight_t* base = &(distances[(source_id * graph->vertex_count)]);
    CHK_CU_SUCCESS(cudaMemcpy(base, distances_d, graph->vertex_count *
                              sizeof(weight_t), cudaMemcpyDeviceToHost),
                   err_free_all);

  }
  }

  // Free GPU resources
  finalize_gpu(graph, graph_d, distances_d, changed_d, new_distances_d,
               has_true_d);
  // Return the constructed shortest distances array
  *path_ret = distances;
  return SUCCESS;

  // error handlers
  err_free_all:
  // Free GPU resources
  finalize_gpu(graph, graph_d, distances_d, changed_d, new_distances_d,
               has_true_d);
  err:
   totem_free(distances, TOTEM_MEM_HOST_PINNED);
   *path_ret = NULL;
   return FAILURE;
}

/**
 * CPU implementation of the All-Pairs Shortest Path algorithm.
 */
error_t apsp_cpu(graph_t* graph, weight_t** path_ret) {
  bool finished;
  error_t ret_val = check_special_cases(graph, path_ret, &finished);
  if (finished) return ret_val;

  vid_t v_count = graph->vertex_count;
  // The distances array mimics a static array to avoid the overhead of
  // creating an array of pointers. Thus, accessing index [i][j] will be
  // done as distances[(i * v_count) + j]
  weight_t* distances = NULL;
  CALL_SAFE(totem_malloc(graph->vertex_count * graph->vertex_count * 
                         sizeof(weight_t), TOTEM_MEM_HOST_PINNED, 
                         (void**)&distances));

  // Initialize the path cost from the edge list
  for (vid_t src = 0; src < v_count; src++) {
    weight_t* base = &distances[src * v_count];
    // Initialize path lengths to WEIGHT_MAX.
    for (vid_t dest = 0; dest < v_count; dest++) {
      base[dest] = (weight_t)WEIGHT_MAX;
    }
    for (eid_t edge = graph->vertices[src]; edge < graph->vertices[src + 1];
         edge++) {
      base[graph->edges[edge]] = graph->weights[edge];
    }
    // 0 distance to oneself
    base[src] = 0;
  }

  // Run the main loop |V| times to converge.
  for (vid_t mid = 0; mid < v_count; mid++) {
    OMP(omp parallel for)
    for (vid_t src = 0; src < v_count; src++) {
      weight_t* base = &distances[src * v_count];
      weight_t* mid_base = &distances[mid * v_count];
      for (vid_t dest = 0; dest < v_count; dest++) {
        base[dest] = min(base[dest], base[mid] + mid_base[dest]);
      }
    }
  }

  *path_ret = distances;
  return SUCCESS;
}
